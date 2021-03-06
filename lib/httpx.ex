defmodule HTTPX do
  @moduledoc ~S"""
  Simple HTTP(s) client with integrated auth methods.
  """

  alias HTTPX.RequestError
  alias HTTPX.Response

  @type post_body ::
          String.t() | {:urlencoded, map | keyword} | {:json, map | keyword | String.t()}

  @default_auth [
    basic: HTTPX.Auth.Basic
  ]
  @auth_methods Application.get_env(:httpx, :auth_extensions, []) ++ @default_auth

  @default_settings [
    ssl_options: [versions: [:"tlsv1.2"]],
    pool: :default,
    connect_timeout: 5_000,
    recv_timeout: 15_000
  ]

  @doc false
  def __default_settings__, do: @default_settings

  @post_header_urlencoded {"Content-Type", "application/x-www-form-urlencoded"}
  @post_header_json {"Content-Type", "application/json"}
  @post_header_file {"Content-Type", "application/octet-stream"}

  @dialyzer {
    [:no_return, :no_match, :nowarn_function],
    get: 1, get: 2, request: 2, request: 3
  }

  @doc ~S"""
  Performs a get request.

  For options see: `&request/3`.
  """
  @spec get(String.t(), keyword) :: {:ok, Response.t()} | {:error, term}
  def get(url, options \\ []), do: :get |> request(url, options)

  @doc ~S"""
  Performs a post request, passing the body in the options.

  For options see: `&request/3`.
  """
  @spec post(String.t(), post_body, keyword) :: {:ok, Response.t()} | {:error, term}
  def post(url, body, options \\ []) do
    with {:ok, opts} <- body_encoding(body, options) do
      request(:post, url, opts)
    end
  end

  @doc ~S"""
  Performs a patch request, passing the body in the options.

  For options see: `&request/3`.
  """
  @spec patch(String.t(), post_body, keyword) :: {:ok, Response.t()} | {:error, term}
  def patch(url, body, options \\ []) do
    with {:ok, opts} <- body_encoding(body, options) do
      request(:patch, url, opts)
    end
  end

  @doc ~S"""
  Performs a put request, passing the body in the options.

  For options see: `&request/3`.
  """
  @spec put(String.t(), post_body, keyword) :: {:ok, Response.t()} | {:error, term}
  def put(url, body, options \\ []) do
    with {:ok, opts} <- body_encoding(body, options) do
      request(:put, url, opts)
    end
  end

  @doc ~S"""
  Performs a delete request.

  For options see: `&request/3`.
  """
  @spec delete(String.t(), keyword) :: {:ok, Response.t()} | {:error, term}
  def delete(url, options \\ []), do: :delete |> request(url, options)

  @doc ~S"""
  Performs a request.

  The given `method` is used and the `url` is called.

  The following options can be set:

    * `:body`, the body to send with the request.
    * `:params`, a map containing query params.
    * `:headers`, list of header tuples.
    * `:settings`, options to pass along to `:hackney`.
    * `:fail`, will error out any request with a non 2xx response code, when set to true.
    * `:auth`, set authorization options.
    * `:format`, set to parse. (Like `:json`)
    * `:retry`, set to retry the request. See the retry options.
  """
  @spec request(term, String.t(), keyword) :: {:ok, Response.t()} | {:error, term}
  def request(method, url, options \\ []) do
    full_url = generate_url(url, options)

    headers = options[:headers] || []

    headers =
      if List.keymember?(headers, "user-agent", 0),
        do: headers,
        else: [{"user-agent", "HTTPX/0.0.12"} | headers]

    body = options[:body] || ""

    hackney_settings =
      @default_settings
      |> Keyword.merge(options[:settings] || [])
      |> Kernel.++([:with_body])

    auth = options[:auth]

    headers =
      case @auth_methods[auth] || auth do
        nil ->
          headers

        auth_method ->
          # 💖 Pipes
          method
          |> auth_method.auth(full_url, headers, body, options)
          |> Kernel.++(headers)
      end

    method
    |> :hackney.request(full_url, headers, body, hackney_settings)
    |> parse_response(options[:format] || :text)
    |> handle_response(options[:fail] || false)
  end

  @doc ~S"""
  Performs a request on all IPs associated with the host DNS.

  For more information see: `request/3`.
  """
  @spec multi_request(term, String.t(), keyword) :: %{ok: map, error: map}
  def multi_request(method, url, opts \\ []) do
    uri = %{host: host} = URI.parse(url)
    opts = Keyword.update(opts, :headers, [{"Host", host}], &[{"Host", host} | &1])

    host
    |> String.to_charlist()
    |> :inet_res.lookup(:in, :a)
    |> Enum.map(&(&1 |> Tuple.to_list() |> Enum.join(".")))
    |> Enum.map(&{&1, request(method, to_string(%{uri | host: &1}), opts)})
    |> Enum.group_by(&elem(elem(&1, 1), 0))
    |> Enum.into(%{})
    |> Map.update(:ok, [], &Enum.into(&1, %{}, fn {ip, r} -> {ip, elem(r, 1)} end))
    |> Map.update(:error, [], &Enum.into(&1, %{}))
  end

  ### Helpers ###

  defp generate_url(url, options) do
    uri = URI.parse(url)

    full_url =
      cond do
        not Keyword.has_key?(options, :params) ->
          url

        uri.query ->
          url <> "&" <> query_encode(options[:params] || %{})

        uri.path ->
          url <> "?" <> query_encode(options[:params] || %{})

        true ->
          url <> "/?" <> query_encode(options[:params] || %{})
      end

    full_url
    |> to_string
    |> default_process_url
  end

  defp parse_response({:ok, status, resp_headers, resp_body}, format) do
    with {:ok, body} <- parse_body(resp_body, format) do
      response = %Response{
        status: status,
        headers: resp_headers,
        body: body
      }

      {:ok, response}
    else
      error -> error
    end
  end

  defp parse_response({:ok, status, resp_headers}, format) do
    parse_response({:ok, status, resp_headers, ""}, format)
  end

  defp parse_response(error, _format) do
    error
  end

  defp parse_body(body, format)

  defp parse_body(body, :text), do: {:ok, body}
  defp parse_body(body, :json), do: body |> Jason.decode() |> error_tuple_normalize()

  defp parse_body(body, :json_atoms),
    do: body |> Jason.decode(keys: :atoms) |> error_tuple_normalize()

  defp parse_body(body, :json_atoms!),
    do: body |> Jason.decode(keys: :atoms!) |> error_tuple_normalize()

  defp error_tuple_normalize(error = {:error, _}), do: error
  defp error_tuple_normalize({:error, _, _}), do: {:error, :invalid_json}
  defp error_tuple_normalize(ok = {:ok, _}), do: ok
  defp error_tuple_normalize(_), do: {:error, :invalid_json_generic}

  defp handle_response({:ok, %{status: status}}, true)
       when status < 200 or status >= 300,
       do: {:error, :http_status_failure}

  defp handle_response(response, _), do: response

  defp default_process_url(url) do
    case url |> String.slice(0, 12) |> String.downcase() do
      "http://" <> _ -> url
      "https://" <> _ -> url
      "http+unix://" <> _ -> url
      _ -> "http://" <> url
    end
  end

  ### Query Encoding ###

  def query_encode(data) do
    data
    |> query_encode("")
    |> query_encode_to_binary()
  end

  defp query_encode(data, prefix) do
    Enum.flat_map(data, fn {field, value} ->
      key =
        if prefix == "",
          do: URI.encode_www_form(to_string(field)),
          else: [prefix, ?[, URI.encode_www_form(to_string(field)), ?]]

      if is_map(value) or is_list(value) do
        query_encode(value, key)
      else
        [?&, key, ?=, URI.encode_www_form(to_string(value))]
      end
    end)
  end

  defp query_encode_to_binary([?& | data]), do: IO.iodata_to_binary(data)
  defp query_encode_to_binary(data), do: IO.iodata_to_binary(data)

  defp body_encoding({:urlencoded, body}, options) do
    {:ok,
     options
     |> Keyword.update(:headers, [@post_header_urlencoded], &[@post_header_urlencoded | &1])
     |> Keyword.put(:body, query_encode(body))}
  end

  defp body_encoding({:file, body}, options) do
    {:ok,
     options
     |> Keyword.update(:headers, [@post_header_file], &[@post_header_file | &1])
     |> Keyword.put(:body, body)}
  end

  defp body_encoding({:json, body}, options) do
    with {:ok, body} <- Jason.encode(body) do
      {:ok,
       options
       |> Keyword.update(:headers, [@post_header_json], &[@post_header_json | &1])
       |> Keyword.put(:body, body)}
    else
      _error -> {:error, :body_not_valid_json}
    end
  end

  defp body_encoding(body, options), do: {:ok, Keyword.put(options, :body, body)}

  ## Bangified ###

  @doc ~S"""
  Performs a get request.

  For options see: `&get/2`.
  """
  @spec get!(String.t(), keyword) :: Response.t()
  def get!(url, options \\ []) do
    case request(:get, url, options) do
      {:ok, response} ->
        response

      {:error, reason} ->
        context = [
          url: url,
          options: options
        ]

        raise RequestError.exception(reason, nil, context)
    end
  end

  @doc ~S"""
  Performs a post request, passing the body in the options.

  For options see: `&post/3`.
  """
  @spec post!(String.t(), post_body, keyword) :: Response.t()
  def post!(url, body, options \\ []) do
    case post(url, body, options) do
      {:ok, response} ->
        response

      {:error, reason} ->
        context = [
          url: url,
          body: body,
          options: options
        ]

        raise RequestError.exception(reason, nil, context)
    end
  end

  @doc ~S"""
  Performs a patch request, passing the body in the options.

  For options see: `&patch/3`.
  """
  @spec patch!(String.t(), post_body, keyword) :: Response.t()
  def patch!(url, body, options \\ []) do
    case patch(url, body, options) do
      {:ok, response} ->
        response

      {:error, reason} ->
        context = [
          url: url,
          body: body,
          options: options
        ]

        raise RequestError.exception(reason, nil, context)
    end
  end

  @doc ~S"""
  Performs a post request, passing the body in the options.

  For options see: `&put/3`.
  """
  @spec put!(String.t(), post_body, keyword) :: Response.t()
  def put!(url, body, options \\ []) do
    case put(url, body, options) do
      {:ok, response} ->
        response

      {:error, reason} ->
        context = [
          url: url,
          body: body,
          options: options
        ]

        raise RequestError.exception(reason, nil, context)
    end
  end

  @doc ~S"""
  Performs a delete request.

  For options see: `&delete/2`.
  """
  @spec delete!(String.t(), keyword) :: Response.t()
  def delete!(url, options \\ []) do
    case request(:delete, url, options) do
      {:ok, response} ->
        response

      {:error, reason} ->
        context = [
          url: url,
          options: options
        ]

        raise RequestError.exception(reason, nil, context)
    end
  end
end
