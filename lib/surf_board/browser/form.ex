defmodule SurfBoard.Browser.Form do
  @moduledoc false

  # fill_in/3, clear/2,3, attach_file/3, set_value/3, send_keys/2,3,
  # grant_permissions/2. Depends on Browser.Internal, Browser.Query
  # (find/find_lazy), and Browser.LiveViewPatch (with_patch_await, and
  # fill_in's own deferred-patch handling).

  alias SurfBoard.Browser.Internal
  alias SurfBoard.Browser.LiveViewPatch
  alias SurfBoard.Browser.Query
  alias SurfBoard.Element
  alias SurfBoard.Session

  @type parent :: Element.t() | Session.t()

  @spec fill_in(parent, SurfBoard.Query.t(), keyword) :: parent
  def fill_in(%Session{} = parent, query, opts) when is_list(opts) do
    value = Keyword.fetch!(opts, :with)
    await_mode = Keyword.get(opts, :await, :auto)

    cond do
      parent.live_view_aware? and await_mode == :defer ->
        # Deferred: use the same fused single-roundtrip pipeline,
        # but force `drain_idle_ms: 0` so the JS-side skips the
        # in-band patch drain. Arm a patch promise BEAM-side
        # beforehand so a subsequent `SurfBoard.LiveView.await_patch/2`
        # can resolve on the next patch.
        armed = SurfBoard.LiveView.arm_next_patch(parent)

        _ =
          Query.find_lazy(parent, query, fn element ->
            session = Element.root_session(element)
            Internal.spec(session).wire_protocol.fill_in(session, element, value, 0)
          end)

        armed

      true ->
        # Fused: one round-trip does silent clear + set_value + (on
        # phx-change forms, when live_view_aware?, drain_patches).
        # Saves two round-trips vs the legacy element-op-per-step.
        drain_idle_ms =
          if parent.live_view_aware? and
               LiveViewPatch.classify_interaction(parent, query, :change) != :none,
             do: 300,
             else: 0

        Query.find_lazy(parent, query, fn element ->
          session = Element.root_session(element)
          Internal.spec(session).wire_protocol.fill_in(session, element, value, drain_idle_ms)
        end)
    end
  end

  @spec clear(parent, SurfBoard.Query.t()) :: parent
  @spec clear(parent, SurfBoard.Query.t(), keyword) :: parent
  def clear(parent, query), do: clear(parent, query, [])

  def clear(parent, query, opts) when is_list(opts) do
    LiveViewPatch.with_patch_await(
      parent,
      query,
      :change,
      fn ->
        parent
        |> Query.find_lazy(query, &Element.clear/1)
      end,
      opts
    )
  end

  @spec attach_file(parent, SurfBoard.Query.t(), path: String.t()) :: parent
  def attach_file(parent, query, path: path) do
    set_value(parent, query, :filename.absname(path))
  end

  @spec set_value(parent, SurfBoard.Query.t(), Element.value()) :: parent
  def set_value(parent, query, :selected) do
    if Internal.remote_session?(Internal.get_session(parent)) do
      Query.find_lazy(parent, query, fn element ->
        session = Element.root_session(element)
        Internal.spec(session).wire_protocol.set_checked(session, element, true)
      end)
    else
      Query.find(parent, query, fn element ->
        case Element.selected?(element) do
          true -> :ok
          false -> Element.click(element)
        end
      end)
    end
  end

  def set_value(parent, query, :unselected) do
    if Internal.remote_session?(Internal.get_session(parent)) do
      Query.find_lazy(parent, query, fn element ->
        session = Element.root_session(element)
        Internal.spec(session).wire_protocol.set_checked(session, element, false)
      end)
    else
      Query.find(parent, query, fn element ->
        case Element.selected?(element) do
          false -> :ok
          true -> Element.click(element)
        end
      end)
    end
  end

  def set_value(parent, query, value) do
    Query.find_lazy(parent, query, fn element ->
      element
      |> Element.set_value(value)
    end)
  end

  @spec send_keys(parent, SurfBoard.Query.t(), Element.keys_to_send()) :: parent
  @spec send_keys(parent, Element.keys_to_send()) :: parent
  def send_keys(parent, query, list) do
    LiveViewPatch.with_patch_await(parent, query, :change, fn ->
      Query.find_lazy(parent, query, fn element ->
        element
        |> Element.send_keys(list)
      end)
    end)
  end

  def send_keys(%Element{} = element, keys) do
    Element.send_keys(element, keys)
  end

  def send_keys(parent, keys) when is_binary(keys) do
    send_keys(parent, [keys])
  end

  def send_keys(%Session{} = parent, keys) when is_list(keys) do
    case Internal.spec(parent).send_keys_session do
      SurfBoard.SendKeysSession.Unsupported ->
        raise SurfBoard.DriverError.not_supported("send_keys/2", parent.spec_module)

      mod ->
        {:ok, _} = mod.send_keys_to_session(parent, keys)
        parent
    end
  end

  @spec grant_permissions(Session.t(), [:camera | :microphone]) :: :ok | {:error, term}
  def grant_permissions(%Session{} = session, permissions) when is_list(permissions) do
    case Internal.spec(session).grant_permissions do
      SurfBoard.Permissions.Unsupported ->
        raise SurfBoard.DriverError.not_supported("grant_permissions/2", session.spec_module)

      mod ->
        mod.grant_permissions(session, permissions)
    end
  end
end
