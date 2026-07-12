defmodule HermitWeb.RouterTest do
  use HermitWeb.ConnCase, async: true

  test "GET unknown path returns 404 Not Found", %{conn: conn} do
    conn = get(conn, "/some-non-existent-page")
    assert conn.status == 404
    assert conn.resp_body == "Not Found"
  end

  test "POST unknown path returns 404 Not Found", %{conn: conn} do
    conn = post(conn, "/some-non-existent-page")
    assert conn.status == 404
    assert conn.resp_body == "Not Found"
  end

  test "HEAD unknown path returns 404", %{conn: conn} do
    conn = head(conn, "/some-non-existent-page")
    assert conn.status == 404
  end
end
