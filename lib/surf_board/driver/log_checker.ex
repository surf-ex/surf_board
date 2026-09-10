defmodule SurfBoard.Driver.LogChecker do
  @moduledoc false

  # Drains buffered CDP/BiDi log events from the process mailbox and
  # parses them for JS error detection and console output.
  #
  # Only ever runs when spec.log_check_interactions? is true (both
  # Chrome drivers; Lightpanda doesn't reliably emit these events, so
  # it opts out entirely rather than needing its own parse_log — there
  # was never a second implementation to dispatch between, so
  # parse_log/1 lives here directly instead of on a driver module.

  @internal_log_patterns ["Launching Mapper instance"]
  @log_regex ~r/^(?<url>\S+) (?<line>\d+):(?<column>\d+) (?<message>.*)$/s
  @string_regex ~r/^"(?<string>.+)"$/

  def check_logs!(_session, fun) do
    return_value = fun.()

    drain_log_events()
    |> Enum.each(&parse_log/1)

    return_value
  end

  defp parse_log(%{"level" => "SEVERE", "source" => "javascript", "message" => msg}) do
    if SurfBoard.js_errors?() do
      raise SurfBoard.JSError, msg
    end
  end

  defp parse_log(%{"level" => "INFO", "source" => "console-api", "message" => msg}) do
    if SurfBoard.js_logger() do
      case Regex.named_captures(@log_regex, msg) do
        %{"message" => message} -> print_message(message)
      end
    end
  end

  defp parse_log(_), do: nil

  defp print_message(message) do
    message =
      case Regex.named_captures(@string_regex, message) do
        %{"string" => string} -> format_string(string)
        nil -> message
      end

    IO.puts(SurfBoard.js_logger(), message)
  end

  defp format_string(message) do
    unescaped = String.replace(message, ~r/\\(.)/, "\\1")

    case Jason.decode(unescaped) do
      {:ok, data} -> "\n#{Jason.encode!(data, pretty: true)}"
      {:error, _} -> unescaped
    end
  end

  defp drain_log_events do
    receive do
      {:bidi_event, "log.entryAdded", event} ->
        case translate_log_entry(event) do
          :skip -> drain_log_events()
          entry -> [entry | drain_log_events()]
        end

      {:bidi_event, "Runtime.consoleAPICalled", event} ->
        [translate_cdp_console(event) | drain_log_events()]

      {:bidi_event, "Runtime.exceptionThrown", event} ->
        [translate_cdp_exception(event) | drain_log_events()]

      # transport delivers events as `:v2_event` rather than
      # `:bidi_event`. Same payload shape, different envelope.
      {:v2_event, "Runtime.consoleAPICalled", event} ->
        [translate_cdp_console(event) | drain_log_events()]

      {:v2_event, "Runtime.exceptionThrown", event} ->
        [translate_cdp_exception(event) | drain_log_events()]
    after
      0 -> []
    end
  end

  defp translate_log_entry(event) do
    params = event["params"] || %{}
    text = params["text"] || ""

    if Enum.any?(@internal_log_patterns, &String.contains?(text, &1)) do
      :skip
    else
      level =
        case params["level"] do
          "error" -> "SEVERE"
          "warning" -> "WARNING"
          "info" -> "INFO"
          "debug" -> "DEBUG"
          other -> other || "INFO"
        end

      source =
        case params["type"] do
          "javascript" -> "javascript"
          "console" -> "console-api"
          other -> other || "other"
        end

      source_info = params["source"] || %{}
      url = source_info["url"] || ""
      line = params["lineNumber"] || 0
      column = params["columnNumber"] || 0

      message =
        if url != "" do
          "#{url} #{line}:#{column} #{text}"
        else
          "unknown 0:0 #{text}"
        end

      %{
        "level" => level,
        "source" => source,
        "message" => message
      }
    end
  end

  # CDP Runtime.consoleAPICalled → same format as BiDi log entries
  defp translate_cdp_console(event) do
    params = event["params"] || %{}
    type = params["type"] || "log"

    level =
      case type do
        "error" -> "SEVERE"
        "warning" -> "WARNING"
        "debug" -> "DEBUG"
        _ -> "INFO"
      end

    args = params["args"] || []

    text =
      Enum.map_join(args, " ", fn
        %{"value" => v} when is_binary(v) -> v
        %{"value" => v} -> inspect(v)
        %{"description" => d} -> d
        %{"type" => "undefined"} -> "undefined"
        other -> inspect(other)
      end)

    trace = params["stackTrace"] || %{}
    frames = trace["callFrames"] || []
    {url, line, col} = extract_stack_location(frames)

    %{
      "level" => level,
      "source" => "console-api",
      "message" => "#{url} #{line}:#{col} #{text}"
    }
  end

  # CDP Runtime.exceptionThrown → SEVERE log entry
  defp translate_cdp_exception(event) do
    params = event["params"] || %{}
    detail = params["exceptionDetails"] || %{}
    exception = detail["exception"] || %{}
    text = exception["description"] || detail["text"] || "Unknown error"

    url = detail["url"] || "unknown"
    line = detail["lineNumber"] || 0
    col = detail["columnNumber"] || 0

    %{
      "level" => "SEVERE",
      "source" => "javascript",
      "message" => "#{url} #{line}:#{col} #{text}"
    }
  end

  defp extract_stack_location([%{"url" => url, "lineNumber" => line, "columnNumber" => col} | _]),
    do: {url, line, col}

  defp extract_stack_location(_), do: {"unknown", 0, 0}
end
