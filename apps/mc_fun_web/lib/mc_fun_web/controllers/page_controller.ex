defmodule McFunWeb.PageController do
  use McFunWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
