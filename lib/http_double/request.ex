defmodule HttpDouble.Request do
  @moduledoc """
  Representation of a parsed HTTP/1.1 request.

  This struct is used internally by the server, mock engine and matchers, and
  is exposed in typespecs so that callback functions in tests can inspect it.
  """

  @enforce_keys [:method, :path, :raw_path, :http_version, :headers, :body]
  defstruct method: "GET",
            path: "/",
            raw_path: "/",
            query: %{},
            http_version: "HTTP/1.1",
            headers: [],
            body: "",
            host: nil,
            port: nil,
            conn_id: nil,
            request_index: 0

  @typedoc "Canonical method name as an uppercase string (e.g. \"GET\")."
  @type method :: String.t()

  @typedoc "Decoded query string key/value map."
  @type query :: %{optional(String.t()) => String.t()}

  @typedoc """
  Parsed HTTP request.

  `headers` is a list of `{name, value}` tuples with lowercase header names.
  """
  @type t :: %__MODULE__{
          method: method(),
          path: String.t(),
          raw_path: String.t(),
          query: query(),
          http_version: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          host: String.t() | nil,
          port: non_neg_integer() | nil,
          conn_id: non_neg_integer() | nil,
          request_index: non_neg_integer()
        }
end
