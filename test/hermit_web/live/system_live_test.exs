defmodule HermitWeb.SystemLiveTest do
  use HermitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders system and updates page correctly", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "System &amp; Updates"
    assert html =~ "Check for Updates"
    assert html =~ "Software Version"
    assert html =~ "Runtime Environment"

    # Test check updates button
    rendered = render_click(view, :check_updates)
    assert rendered =~ "System &amp; Updates"
  end
end
