defmodule HermitWeb.BasicAuthTest do
  use HermitWeb.ConnCase, async: false

  setup do
    # Save original env
    orig_user = System.get_env("HERMIT_BASIC_AUTH_USER")
    orig_pass = System.get_env("HERMIT_BASIC_AUTH_PASS")

    on_exit(fn ->
      if orig_user, do: System.put_env("HERMIT_BASIC_AUTH_USER", orig_user), else: System.delete_env("HERMIT_BASIC_AUTH_USER")
      if orig_pass, do: System.put_env("HERMIT_BASIC_AUTH_PASS", orig_pass), else: System.delete_env("HERMIT_BASIC_AUTH_PASS")
    end)

    :ok
  end

  test "when basic auth env vars are not set, it allows access without credentials", %{conn: conn} do
    System.delete_env("HERMIT_BASIC_AUTH_USER")
    System.delete_env("HERMIT_BASIC_AUTH_PASS")

    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Active VPN Tunnels"
  end

  test "when basic auth env vars are set, it blocks access without credentials", %{conn: conn} do
    System.put_env("HERMIT_BASIC_AUTH_USER", "admin")
    System.put_env("HERMIT_BASIC_AUTH_PASS", "password")

    conn = get(conn, ~p"/")
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Application\""]
  end

  test "when basic auth env vars are set, it allows access with correct credentials", %{conn: conn} do
    System.put_env("HERMIT_BASIC_AUTH_USER", "admin")
    System.put_env("HERMIT_BASIC_AUTH_PASS", "password")

    auth = "Basic " <> Base.encode64("admin:password")

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/")

    assert html_response(conn, 200) =~ "Active VPN Tunnels"
  end

  test "when basic auth env vars are set, it blocks access with incorrect credentials", %{conn: conn} do
    System.put_env("HERMIT_BASIC_AUTH_USER", "admin")
    System.put_env("HERMIT_BASIC_AUTH_PASS", "password")

    auth = "Basic " <> Base.encode64("admin:wrongpassword")

    conn =
      conn
      |> put_req_header("authorization", auth)
      |> get(~p"/")

    assert conn.status == 401
  end
end
