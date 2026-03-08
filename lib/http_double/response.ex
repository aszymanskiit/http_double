defmodule HttpDouble.Response do
  @moduledoc """
  Helpers and struct for building HTTP responses.

  Most callers will use the simple map form:

      %{status: 200, body: "ok"}
      %{status: 201, json: %{result: "accepted"}}

  This module makes it easy to construct responses and turn them into raw
  wire-format bytes to be sent via TCP.
  """

  @enforce_keys [:status]
  defstruct status: 200,
            headers: [],
            body: "",
            json: nil,
            chunked?: false

  @typedoc "Simple HTTP response structure."
  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: iodata(),
          json: map() | list() | nil,
          chunked?: boolean()
        }

  @doc "Builds a plain text response."
  @spec text(non_neg_integer(), iodata(), keyword()) :: t()
  def text(status, body, opts \\ []) do
    headers =
      [
        {"content-type", "text/plain; charset=utf-8"}
      ] ++ Keyword.get(opts, :headers, [])

    %__MODULE__{status: status, headers: headers, body: body}
  end

  @doc "Builds a JSON response using Jason for encoding."
  @spec json(non_neg_integer(), map() | list(), keyword()) :: t()
  def json(status, data, opts \\ []) do
    headers =
      [
        {"content-type", "application/json"}
      ] ++ Keyword.get(opts, :headers, [])

    %__MODULE__{status: status, headers: headers, json: data, body: ""}
  end

  @doc "Builds an empty-body response."
  @spec empty(non_neg_integer(), keyword()) :: t()
  def empty(status, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    %__MODULE__{status: status, headers: headers, body: ""}
  end

  @doc """
  Converts a response specification (map or struct) into raw HTTP/1.1 bytes.

  When `request` is provided, it is used for behaviours like HEAD responses
  (no body even when one is present).
  """
  @spec to_iodata(map() | t(), HttpDouble.Request.t() | nil) :: iodata()
  def to_iodata(spec, request \\ nil)

  def to_iodata(%__MODULE__{} = resp, request) do
    encode_struct(resp, request)
  end

  def to_iodata(%{status: status} = map, request) when is_integer(status) do
    struct = %__MODULE__{
      status: status,
      headers: Map.get(map, :headers, []),
      body: Map.get(map, :body, ""),
      json: Map.get(map, :json, nil),
      chunked?: Map.get(map, :chunked?, false)
    }

    encode_struct(struct, request)
  end

  defp encode_struct(%__MODULE__{} = resp, request) do
    {body, headers} =
      case resp.json do
        nil ->
          {IO.iodata_to_binary(resp.body || ""), resp.headers}

        data ->
          encoded = Jason.encode!(data)

          headers =
            [{"content-type", "application/json"}] ++
              Enum.reject(resp.headers, fn {name, _} ->
                String.downcase(name) == "content-type"
              end)

          {encoded, headers}
      end

    status_line =
      "HTTP/1.1 " <> Integer.to_string(resp.status) <> " " <> reason_phrase(resp.status)

    headers =
      headers
      |> Enum.map(fn {name, value} -> {String.downcase(name), value} end)
      |> ensure_connection_keep_alive()
      |> ensure_content_length(body, request)

    header_lines =
      Enum.map(headers, fn {name, value} ->
        name_out =
          case name do
            "content-type" -> "Content-Type"
            "content-length" -> "Content-Length"
            "connection" -> "Connection"
            other -> other
          end

        name_out <> ": " <> value
      end)

    [
      status_line,
      "\r\n",
      Enum.intersperse(header_lines, "\r\n"),
      "\r\n\r\n",
      maybe_strip_body(body, request)
    ]
  end

  defp ensure_connection_keep_alive(headers) do
    has_connection? =
      Enum.any?(headers, fn {name, _} -> String.downcase(name) == "connection" end)

    if has_connection?, do: headers, else: [{"connection", "keep-alive"} | headers]
  end

  defp ensure_content_length(headers, body, request) do
    has_length? =
      Enum.any?(headers, fn {name, _} -> String.downcase(name) == "content-length" end)

    length_value =
      if has_length? do
        nil
      else
        body_to_measure = maybe_strip_body(body, request)
        Integer.to_string(byte_size(body_to_measure))
      end

    case length_value do
      nil -> headers
      value -> [{"content-length", value} | headers]
    end
  end

  defp maybe_strip_body(_body, %HttpDouble.Request{method: "HEAD"}), do: ""
  defp maybe_strip_body(body, _), do: body

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(201), do: "Created"
  defp reason_phrase(202), do: "Accepted"
  defp reason_phrase(204), do: "No Content"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(403), do: "Forbidden"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(405), do: "Method Not Allowed"
  defp reason_phrase(408), do: "Request Timeout"
  defp reason_phrase(409), do: "Conflict"
  defp reason_phrase(429), do: "Too Many Requests"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(502), do: "Bad Gateway"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(_), do: "OK"
end
