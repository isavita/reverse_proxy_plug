defmodule ReverseProxyPlugTest do
  import TestReuse, only: :macros
  use ExUnit.Case
  use Plug.Test

  import Mox

  @opts [
    upstream: "example.com",
    client: ReverseProxyPlug.HTTPClientMock
  ]

  @hop_by_hop_headers [
    {"connection", "keep-alive"},
    {"keep-alive", "timeout=5, max=1000"},
    {"upgrade", "h2c"},
    {"proxy-authenticate", "Basic"},
    {"proxy-authorization", "Basic abcd"},
    {"te", "compress"},
    {"trailer", "Expires"}
  ]

  @end_to_end_headers [
    {"cache-control", "max-age=3600"},
    {"cookie", "acookie"},
    {"date", "Tue, 15 Nov 1994 08:12:31 GMT"}
  ]

  @host_header [
    {"host", "example.com"}
  ]

  setup :verify_on_exit!

  test "receives buffer response" do
    headers = [{"host", "example.com"}, {"content-length", "42"}]

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, TestReuse.get_buffer_responder(%{headers: headers}))

    conn =
      conn(:get, "/")
      |> ReverseProxyPlug.call(
        ReverseProxyPlug.init(Keyword.merge(@opts, response_mode: :buffer))
      )

    assert conn.status == 200, "passes status through"
    assert Enum.all?(headers, fn x -> x in conn.resp_headers end), "passes headers through"
    assert conn.resp_body == "Success", "passes body through"
  end

  test "does not add transfer-encoding header to response" do
    headers = [{"host", "example.com"}, {"content-length", "42"}]

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, TestReuse.get_buffer_responder(%{headers: headers}))

    conn =
      conn(:get, "/")
      |> ReverseProxyPlug.call(
        ReverseProxyPlug.init(Keyword.merge(@opts, response_mode: :buffer))
      )

    resp_header_names =
      conn.resp_headers
      |> Enum.map(fn {name, _val} -> name end)

    refute "transfer-encoding" in resp_header_names,
           "does not add transfer-encoding header"
  end

  test "does not add transfer-encoding header to response if request was chunk encoded" do
    headers = [{"host", "example.com"}, {"transfer-encoding", "chunked"}]

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, TestReuse.get_buffer_responder(%{headers: headers}))

    conn =
      conn(:get, "/")
      |> ReverseProxyPlug.call(
        ReverseProxyPlug.init(Keyword.merge(@opts, response_mode: :buffer))
      )

    resp_header_names =
      conn.resp_headers
      |> Enum.map(fn {name, _val} -> name end)

    refute "transfer-encoding" in resp_header_names,
           "does not add transfer-encoding header"
  end

  test "receives stream response" do
    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, TestReuse.get_stream_responder(%{headers: @host_header}))

    conn =
      conn(:get, "/")
      |> ReverseProxyPlug.call(ReverseProxyPlug.init(@opts))

    assert conn.status == 200, "passes status through"
    assert {"host", "example.com"} in conn.resp_headers, "passes headers through"
    assert conn.resp_body == "Success", "passes body through"
  end

  test "sets correct chunked transfer-encoding headers" do
    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, TestReuse.get_stream_responder(%{headers: [{"content-length", "7"}]}))

    conn =
      conn(:get, "/")
      |> ReverseProxyPlug.call(ReverseProxyPlug.init(@opts))

    assert {"transfer-encoding", "chunked"} in conn.resp_headers,
           "sets transfer-encoding header"

    resp_header_names =
      conn.resp_headers
      |> Enum.map(fn {name, _val} -> name end)

    refute "content-length" in resp_header_names,
           "deletes the content-length header"
  end

  test "appends params to the request's body" do
    body = ReverseProxyPlug.read_body(conn(:post, "/users", %{"user" => %{"name" => "Jane Doe"}}))

    assert body == "--plug_conn_test--&user[name]=Jane+Doe"
  end

  test "appends params and query string params to the request's body" do
    body =
      ReverseProxyPlug.read_body(
        conn(:post, "/users?type=customer", %{"user" => %{"name" => "Jane Doe"}})
      )

    assert body == "--plug_conn_test--&type=customer&user[name]=Jane+Doe"
  end

  test "does not append `&` to the reqeust's body if params are not provide" do
    body = ReverseProxyPlug.read_body(conn(:post, "/users", %{}))

    refute body =~ "&"
  end

  test_stream_and_buffer "removes hop-by-hop headers before forwarding request" do
    %{opts: opts, get_responder: get_responder} = test_reuse_opts

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, fn %{headers: headers} = request ->
      send(self(), {:headers, headers})
      get_responder.(%{}).(request)
    end)

    conn(:get, "/")
    |> Map.put(:req_headers, @hop_by_hop_headers ++ @end_to_end_headers)
    |> ReverseProxyPlug.call(ReverseProxyPlug.init(opts))

    assert_receive {:headers, headers}
    assert @end_to_end_headers == headers
  end

  test_stream_and_buffer "removes hop-by-hop headers from response" do
    %{opts: opts, get_responder: get_responder} = test_reuse_opts

    ReverseProxyPlug.HTTPClientMock
    |> expect(
      :request,
      get_responder.(%{headers: @hop_by_hop_headers ++ @end_to_end_headers})
    )

    conn =
      conn(:get, "/")
      |> ReverseProxyPlug.call(ReverseProxyPlug.init(opts))

    assert Enum.all?(@hop_by_hop_headers, fn x -> x not in conn.resp_headers end),
           "deletes hop-by-hop headers"

    assert Enum.all?(@end_to_end_headers, fn x -> x in conn.resp_headers end),
           "passes other headers through"
  end

  test_stream_and_buffer "returns bad gateway on error" do
    %{opts: opts} = test_reuse_opts
    error = {:error, :some_reason}

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, fn _request ->
      error
    end)

    conn = conn(:get, "/") |> ReverseProxyPlug.call(ReverseProxyPlug.init(opts))

    assert conn.status === 502
  end

  test_stream_and_buffer "calls error callback if supplied" do
    %{opts: opts} = test_reuse_opts
    error = {:error, :some_reason}

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, fn _request ->
      error
    end)

    opts_with_callback =
      Keyword.merge(opts, error_callback: fn err -> send(self(), {:got_error, err}) end)

    conn(:get, "/") |> ReverseProxyPlug.call(ReverseProxyPlug.init(opts_with_callback))

    assert_receive({:got_error, error})
  end

  test_stream_and_buffer "handles request path and query string" do
    %{opts: opts, get_responder: get_responder} = test_reuse_opts

    opts_with_upstream = Keyword.merge(opts, upstream: "//example.com/root_upstream?query=yes")

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, fn %{url: url} = request ->
      send(self(), {:url, url})
      get_responder.(%{}).(request)
    end)

    conn(:get, "/root_path")
    |> ReverseProxyPlug.call(ReverseProxyPlug.init(opts_with_upstream))

    assert_receive {:url, url}
    assert "http://example.com:80/root_upstream/root_path?query=yes" == url
  end

  test_stream_and_buffer "preserves trailing slash at the end of request path" do
    %{opts: opts, get_responder: get_responder} = test_reuse_opts
    opts_with_upstream = Keyword.merge(opts, upstream: "//example.com")

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, fn %{url: url} = request ->
      send(self(), {:url, url})
      get_responder.(%{}).(request)
    end)

    conn(:get, "/root_path/")
    |> ReverseProxyPlug.call(ReverseProxyPlug.init(opts_with_upstream))

    assert_receive {:url, url}
    assert url == "http://example.com:80/root_path/"
  end

  test_stream_and_buffer "include the port in the host header when is not the default and preserve_host_header is false in opts" do
    %{opts: opts, get_responder: get_responder} = test_reuse_opts
    opts_with_upstream = Keyword.merge(opts, upstream: "//example-custom-port.com:8081")

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, fn %{headers: headers} = request ->
      send(self(), {:headers, headers})
      get_responder.(%{}).(request)
    end)

    conn(:get, "/")
    |> Plug.Conn.put_req_header("host", "custom.com:9999")
    |> ReverseProxyPlug.call(ReverseProxyPlug.init(opts_with_upstream))

    assert_receive {:headers, headers}
    assert [{"host", "example-custom-port.com:8081"}] == headers
  end

  test_stream_and_buffer "don't include the port in the host header when is the default and preserve_host_header is false in opts" do
    %{opts: opts, get_responder: get_responder} = test_reuse_opts
    opts_with_upstream = Keyword.merge(opts, upstream: "//example-custom-port.com:80")

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, fn %{headers: headers} = request ->
      send(self(), {:headers, headers})
      get_responder.(%{}).(request)
    end)

    conn(:get, "/")
    |> Plug.Conn.put_req_header("host", "custom.com:9999")
    |> ReverseProxyPlug.call(ReverseProxyPlug.init(opts_with_upstream))

    assert_receive {:headers, headers}
    assert [{"host", "example-custom-port.com"}] == headers
  end

  test_stream_and_buffer "don't include the port in the host header when is the default for https and preserve_host_header is false in opts" do
    %{opts: opts, get_responder: get_responder} = test_reuse_opts
    opts_with_upstream = Keyword.merge(opts, upstream: "https://example-custom-port.com:443")

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, fn %{headers: headers} = request ->
      send(self(), {:headers, headers})
      get_responder.(%{}).(request)
    end)

    conn(:get, "/")
    |> Plug.Conn.put_req_header("host", "custom.com:9999")
    |> ReverseProxyPlug.call(ReverseProxyPlug.init(opts_with_upstream))

    assert_receive {:headers, headers}
    assert [{"host", "example-custom-port.com"}] == headers
  end

  test_stream_and_buffer "returns gateway timeout on connect timeout" do
    %{opts: opts} = test_reuse_opts

    conn = :get |> conn("/") |> simulate_upstream_error(:connect_timeout, opts)

    assert conn.status === 504
  end

  test_stream_and_buffer "returns gateway timeout on timeout" do
    %{opts: opts} = test_reuse_opts

    conn = :get |> conn("/") |> simulate_upstream_error(:timeout, opts)

    assert conn.status === 504
  end

  test_stream_and_buffer "returns gateway error on a generic error" do
    %{opts: opts} = test_reuse_opts

    conn = :get |> conn("/") |> simulate_upstream_error(:some_error, opts)

    assert conn.status === 502
  end

  test_stream_and_buffer "passes timeout options to HTTP client" do
    %{opts: opts, get_responder: get_responder} = test_reuse_opts
    timeout_val = 5_000

    opts_with_client_options =
      Keyword.merge(opts, client_options: [timeout: timeout_val, recv_timeout: timeout_val])

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, fn %{options: options} = request ->
      send(self(), {:httpclient_options, options})
      get_responder.(%{}).(request)
    end)

    :get |> conn("/") |> ReverseProxyPlug.call(ReverseProxyPlug.init(opts_with_client_options))

    assert_receive {:httpclient_options, httpclient_options}
    assert timeout_val == httpclient_options[:timeout]
    assert timeout_val == httpclient_options[:recv_timeout]
  end

  defp simulate_upstream_error(conn, reason, opts) do
    error = {:error, %HTTPoison.Error{id: nil, reason: reason}}

    ReverseProxyPlug.HTTPClientMock
    |> expect(:request, fn _request ->
      error
    end)

    ReverseProxyPlug.call(conn, ReverseProxyPlug.init(opts))
  end
end
