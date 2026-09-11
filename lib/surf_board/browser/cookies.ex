defmodule SurfBoard.Browser.Cookies do
  @moduledoc false

  # cookies/1, set_cookie/4, blank_page?/1. Depends only on
  # Browser.Internal (spec/1).

  alias SurfBoard.Browser.Internal
  alias SurfBoard.CookieError
  alias SurfBoard.Session

  def cookies(%Session{} = session) do
    {:ok, cookies_list} = Internal.spec(session).wire_protocol.cookies(session)

    cookies_list
  end

  def set_cookie(%Session{} = session, key, value, attributes \\ []) do
    if blank_page?(session) do
      raise CookieError
    end

    case Internal.spec(session).wire_protocol.set_cookie(session, key, value, Map.new(attributes)) do
      {:ok, _list} ->
        session

      {:error, :invalid_cookie_domain} ->
        raise CookieError
    end
  end

  @doc false
  def blank_page?(%Session{} = session) do
    Internal.spec(session).wire_protocol.blank_page?(session)
  end
end
