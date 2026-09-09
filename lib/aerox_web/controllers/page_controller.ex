defmodule AeroxWeb.PageController do
  use AeroxWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
