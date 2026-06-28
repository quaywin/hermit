defmodule HermitWeb.PageController do
  use HermitWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
