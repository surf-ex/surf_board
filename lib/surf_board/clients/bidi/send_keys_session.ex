defmodule SurfBoard.Clients.BiDi.SendKeysSession do
  @moduledoc false

  # Session-scoped send_keys for BiDi: dispatches a key sequence to
  # whatever element currently has page focus via
  # input.performActions. The wire send goes through
  # Transport.Protocol directly (matching Clients.BiDi.Client's own
  # style), not through Clients.BiDi.Client.

  @behaviour SurfBoard.SendKeysSession

  alias SurfBoard.Clients.BiDi.Commands
  alias SurfBoard.Session
  alias SurfBoard.Transport.Protocol

  @doc """
  Send a key sequence (text + special atoms like :tab, :enter) to
  whatever element currently has focus. BiDi's input.performActions
  with a key-source sequence handles this in one call.
  """
  @impl true
  @spec send_keys_to_session(Session.t(), list) :: {:ok, nil} | {:error, term}
  def send_keys_to_session(%Session{browsing_context: ctx} = session, keys) when is_list(keys) do
    actions = Commands.key_type_actions(keys)
    {method, params} = Commands.perform_actions(ctx, actions)

    case Protocol.cdp_send(session, method, params, []) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end
end
