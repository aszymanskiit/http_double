defmodule HttpDouble.Route do
  @moduledoc """
  Representation of a static HTTP route.

  Routes can be defined as simple maps or as more advanced structures. This
  module normalises external route specifications into a uniform internal form
  and provides matching helpers.
  """

  alias HttpDouble.{MockRule, Request}

  @enforce_keys [:id, :method, :path, :response]
  defstruct id: nil,
            method: "GET",
            path: "/",
            path_prefix: nil,
            path_regex: nil,
            host: nil,
            query: %{},
            header_matches: [],
            body_match: nil,
            response: nil

  @typedoc "Unique route identifier."
  @type id :: reference()

  @typedoc "Internal route representation."
  @type t :: %__MODULE__{
          id: id(),
          method: String.t(),
          path: String.t(),
          path_prefix: String.t() | nil,
          path_regex: Regex.t() | nil,
          host: String.t() | nil,
          query: %{optional(String.t()) => String.t() | :any},
          header_matches: [{String.t(), String.t() | :any | Regex.t()}],
          body_match: nil | binary() | Regex.t(),
          response: HttpDouble.response_spec()
        }

  @doc """
  Builds a route struct from a user-facing map specification.

  Supported keys:

    * `:method` – string or atom, e.g. \"GET\" or :post
    * `:path` – exact path match
    * `:path_prefix` – prefix match
    * `:path_regex` – regular expression
    * `:host` – optional host match
    * `:query` – map of query parameters, values can be exact strings or `:any`
    * `:headers` – header match map or list of `{name, value}` (value can be string, `:any` or regex)
    * `:body` – exact body match or regex
    * `:response` – response specification (map, `HttpDouble.Response`, callback, etc.)
  """
  @spec from_spec(map()) :: t()
  def from_spec(%{} = spec) do
    id = Map.get(spec, :id, make_ref())

    method =
      spec
      |> Map.get(:method, "GET")
      |> normalise_method()

    path = Map.get(spec, :path, "/")

    path_prefix = Map.get(spec, :path_prefix)
    path_regex = Map.get(spec, :path_regex)
    host = Map.get(spec, :host)
    query = Map.get(spec, :query, %{}) |> normalise_query()
    header_matches = Map.get(spec, :headers, []) |> normalise_headers()
    body_match = Map.get(spec, :body_match, Map.get(spec, :body))
    response = Map.fetch!(spec, :response)

    %__MODULE__{
      id: id,
      method: method,
      path: path,
      path_prefix: path_prefix,
      path_regex: path_regex,
      host: host,
      query: query,
      header_matches: header_matches,
      body_match: body_match,
      response: response
    }
  end

  @doc """
  Finds the first matching route and resolves its response specification.
  """
  @spec find_match([t()], Request.t()) ::
          {:ok, t(), HttpDouble.response_spec()} | :nomatch
  def find_match(routes, %Request{} = req) do
    do_find(routes, req)
  end

  defp do_find([], _req), do: :nomatch

  defp do_find([route | rest], req) do
    if matches?(route, req) do
      response_spec = resolve_route_response(route.response, req)

      {:ok, route, response_spec}
    else
      do_find(rest, req)
    end
  end

  defp resolve_route_response({:fun, fun}, req) do
    meta = MockRule.meta_from_request(req, nil)

    args =
      case :erlang.fun_info(fun, :arity) do
        {:arity, 2} -> [req, meta]
        _ -> [req]
      end

    apply(fun, args)
  end

  defp resolve_route_response(response, req) do
    if is_function(response) do
      meta = MockRule.meta_from_request(req, nil)

      args =
        case :erlang.fun_info(response, :arity) do
          {:arity, 2} -> [req, meta]
          _ -> [req]
        end

      apply(response, args)
    else
      response
    end
  end

  @spec matches?(t(), Request.t()) :: boolean()
  defp matches?(route, %Request{} = req) do
    method_match?(route, req) and
      path_match?(route, req) and
      host_match?(route, req) and
      query_match?(route, req) and
      headers_match?(route, req) and
      body_match?(route, req)
  end

  defp method_match?(%__MODULE__{method: route_method}, %Request{method: req_method}) do
    normalise_method(route_method) == normalise_method(req_method)
  end

  defp path_match?(%__MODULE__{path: path, path_prefix: nil, path_regex: nil}, %Request{
         path: path
       }),
       do: true

  defp path_match?(%__MODULE__{path_prefix: prefix} = _route, %Request{path: path})
       when is_binary(prefix) do
    String.starts_with?(path, prefix)
  end

  defp path_match?(%__MODULE__{path_regex: %Regex{} = re}, %Request{path: path}) do
    Regex.match?(re, path)
  end

  defp path_match?(%__MODULE__{path: path}, %Request{path: path}), do: true
  defp path_match?(_route, _req), do: false

  defp host_match?(%__MODULE__{host: nil}, _req), do: true

  defp host_match?(%__MODULE__{host: host}, %Request{host: host}), do: true
  defp host_match?(_route, _req), do: false

  defp query_match?(%__MODULE__{query: query}, %Request{query: req_query}) do
    Enum.all?(query, fn {key, expected} ->
      case {expected, Map.fetch(req_query, key)} do
        {:any, {:ok, _}} -> true
        {value, {:ok, value}} -> true
        _ -> false
      end
    end)
  end

  defp headers_match?(%__MODULE__{header_matches: []}, _req), do: true

  defp headers_match?(%__MODULE__{header_matches: matches}, %Request{headers: headers}) do
    Enum.all?(matches, fn {name, expected} ->
      case find_header(headers, name) do
        nil ->
          false

        value ->
          case expected do
            :any -> true
            %Regex{} = re -> Regex.match?(re, value)
            other -> value == other
          end
      end
    end)
  end

  defp body_match?(%__MODULE__{body_match: nil}, _req), do: true

  defp body_match?(%__MODULE__{body_match: expected}, %Request{body: body})
       when is_binary(expected) do
    body == expected
  end

  defp body_match?(%__MODULE__{body_match: %Regex{} = re}, %Request{body: body}) do
    Regex.match?(re, body)
  end

  defp body_match?(_route, _req), do: false

  defp normalise_method(method) when is_binary(method), do: String.upcase(method)

  defp normalise_method(method) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp normalise_query(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.into(%{})
  end

  defp normalise_query(_), do: %{}

  defp normalise_headers(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), v} end)
  end

  defp normalise_headers(list) when is_list(list) do
    Enum.map(list, fn
      {name, value} -> {String.downcase(to_string(name)), value}
      other -> other
    end)
  end

  defp normalise_headers(_), do: []

  defp find_header(headers, name) do
    lname = String.downcase(name)

    headers
    |> Enum.find_value(fn {n, v} ->
      if n == lname, do: v, else: nil
    end)
  end

  @doc """
  Updates a route inside a route list using either `:id` or `{method, path}`.
  """
  @spec update_in_list([t()], map()) :: [t()]
  def update_in_list(routes, %{} = spec) do
    {id, by_mfa?} =
      case spec do
        %{id: id} -> {id, false}
        %{method: method, path: path} -> {{normalise_method(method), path}, true}
        _ -> {nil, false}
      end

    Enum.map(routes, fn
      %__MODULE__{id: ^id} = route when not by_mfa? ->
        merge_route(route, spec)

      %__MODULE__{method: meth, path: path} = route
      when by_mfa? and
             {meth, path} == id ->
        merge_route(route, spec)

      route ->
        route
    end)
  end

  @doc """
  Deletes a route from the list using either `:id` or `{method, path}`.
  """
  @spec delete_from_list([t()], map()) :: [t()]
  def delete_from_list(routes, %{} = spec) do
    {id, by_mfa?} =
      case spec do
        %{id: id} -> {id, false}
        %{method: method, path: path} -> {{normalise_method(method), path}, true}
        _ -> {nil, false}
      end

    Enum.reject(routes, fn
      %__MODULE__{id: ^id} when not by_mfa? -> true
      %__MODULE__{method: meth, path: path} when by_mfa? and {meth, path} == id -> true
      _ -> false
    end)
  end

  defp merge_route(route, spec) do
    updated = from_spec(Map.merge(Map.from_struct(route), spec))
    %{updated | id: route.id}
  end
end
