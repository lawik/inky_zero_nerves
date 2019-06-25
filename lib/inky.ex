defmodule Inky do
  @moduledoc """
  The Inky module provides the public API for interacting with the display.
  """

  use GenServer

  require Integer
  require Logger

  alias Inky.Display
  alias Inky.RpiHAL

  @push_timeout 5000

  defmodule State do
    @moduledoc false

    @enforce_keys [:display, :hal_state]
    defstruct display: nil,
              hal_mod: RpiHAL,
              hal_state: nil,
              pixels: %{},
              type: nil,
              wait_type: :nowait
  end

  #
  # API
  #

  @doc """
  Start a GenServer that deals with the HAL state (initialization of and communication with the display) and pushing pixels to the physical display. This function will do some of the necessary preparation to enable communication with the display.

  ## Parameters

    - type: Atom for either :phat or :what
    - accent: Accent color, the color the display supports aside form white and black. Atom, :black, :red or :yellow.
  """
  def start_link(args \\ %{}) do
    opts = if(args[:name], do: [name: args[:name]], else: [])
    GenServer.start_link(__MODULE__, args, opts)
  end

  @doc """
  `set_pixels(pid | name, pixels | painter, opts \\ %{push: :await})` set
  pixels and draw to display (or not!), with data or a painter function.

  set_pixels updates the internal state either with specific pixels or by
  calling `painter.(x,y,w,h,current_pixels)` for all points in the screen, in
  an undefined order.

  Currently, the only option checked is `:push`, which represents the minimum
  pixel pushing policy the caller wishes to apply for their request. Valid
  values are listed and explained below.

  NOTE: the internal state of Inky will still be updated, regardless of which
  pushing policy is employed.

  - `:await`: Busy wait until you can push to display, clearing any previously
    set timeout. This is the default.
  - `:once`: Push to the display if it is not busy, otherwise, report that it
    was busy. Only `:await` timeouts are reset if a `:once` push has failed.
  - `{:timeout, :await}`: Use genserver timeouts to avoid multiple updates.
    When the timeout triggers, await device with a busy wait and then push to
    the display. If the timeout previously was :once, it is replaced.
  - `{:timeout, :once}`: Use genserver timeouts to avoid multiple updates. When
    the timeout triggers, update the display if not busy. Does not downgrade a
    previously set `:await` timeout.
  - `:skip`: Do not push to display. If there has been a timeout previously
    set, but that has yet to fire, it will remain set.
  """
  def set_pixels(pid, arg, opts \\ %{}),
    do: GenServer.call(pid, {:set_pixels, arg, opts}, :infinity)

  def show(server, opts \\ %{}) do
    if opts[:async] === true,
      do: GenServer.cast(server, :push),
      else: GenServer.call(server, :push, :infinity)
  end

  def stop(server) do
    GenServer.stop(server)
  end

  #
  # GenServer callbacks
  #

  @impl GenServer
  def init(args) do
    type = Map.fetch!(args, :type)
    accent = Map.fetch!(args, :accent)
    hal_mod = args[:hal_mod] || RpiHAL

    display = Display.spec_for(type, accent)

    hal_state =
      hal_mod.init(%{
        display: display
      })

    {:ok,
     %State{
       display: display,
       hal_mod: hal_mod,
       hal_state: hal_state
     }}
  end

  # GenServer calls

  @impl GenServer
  def handle_call({:set_pixels, arg, opts}, _from, state = %State{wait_type: wt}) do
    state = %State{state | pixels: update_pixels(arg, state)}

    case opts[:push] || :await do
      :await -> push(:await, state) |> reply(:nowait, state)
      :once -> push(:once, state) |> handle_push(state)
      :skip when wt == :nowait -> reply(:ok, :nowait, state)
      :skip -> reply_timeout(wt, state)
      {:timeout, :await} -> reply_timeout(:await, state)
      {:timeout, :once} when wt == :await -> reply_timeout(:await, state)
      {:timeout, :once} -> reply_timeout(:once, state)
    end
  end

  def handle_call(:push, _from, state) do
    {:reply, push(:await, state), state}
  end

  def handle_call(request, from, state) do
    Logger.warn("Dropping unexpected call #{inspect(request)} from #{inspect(from)}")
    {:reply, :ok, state}
  end

  # GenServer casts

  @impl GenServer
  def handle_cast(:push, state) do
    push(:await, state)
    {:noreply, state}
  end

  def handle_cast(request, state) do
    Logger.warn("Dropping unexpected cast #{inspect(request)}")
    {:noreply, state}
  end

  # GenServer messages

  @impl GenServer
  def handle_info(:timeout, state) do
    case push(state.wait_type, state) do
      {:error, reason} -> Logger.error("Failed to push graph on timeout: #{inspect(reason)}")
      :ok -> :ok
    end

    {:noreply, %State{state | wait_type: :nowait}}
  end

  def handle_info(msg, state) do
    Logger.error("Dropping unexpected info message #{inspect(msg)}")
    {:noreply, state}
  end

  #
  # Internal
  #

  # Set pixels

  defp update_pixels(arg, state) do
    case arg do
      arg when is_map(arg) ->
        handle_set_pixels_map(arg, state)

      arg when is_function(arg, 5) ->
        handle_set_pixels_fun(arg, state)
    end
  end

  defp handle_set_pixels_map(pixels, state) do
    Map.merge(state.pixels, pixels)
  end

  defp handle_set_pixels_fun(painter, state) do
    %Display{width: w, height: h} = state.display

    stream_points(w, h)
    |> Enum.reduce(state.pixels, fn {x, y}, acc ->
      Map.put(acc, {x, y}, painter.(x, y, w, h, acc))
    end)
  end

  defp stream_points(w, h) do
    Stream.resource(
      fn -> {{0, 0}, {w - 1, h - 1}} end,
      fn
        {{w, h}, {w, h}} -> {:halt, {w, h}}
        {{w, y}, {w, h}} -> {[{w, y}], {{0, y + 1}, {w, h}}}
        {{x, y}, {w, h}} -> {[{x, y}], {{x + 1, y}, {w, h}}}
      end,
      fn _ -> :ok end
    )
  end

  # GenServer replies

  defp handle_push(e = {:error, :device_busy}, state = %State{wait_type: :await}),
    do: reply_timeout(e, :await, state)

  defp handle_push(response, state), do: reply(response, :nowait, state)

  defp reply(response, timeout_policy, state) do
    {:reply, response, %State{state | wait_type: timeout_policy}}
  end

  defp reply_timeout(response \\ :ok, timeout_policy, state) do
    {:reply, response, %State{state | wait_type: timeout_policy}, @push_timeout}
  end

  # Internals

  defp push(push_policy, state) when not (push_policy in [:await, :once]), do: push(:await, state)

  defp push(push_policy, state) do
    hm = state.hal_mod
    hm.handle_update(state.pixels, push_policy, state.hal_state)
  end
end
