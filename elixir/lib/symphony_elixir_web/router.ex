defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    get("/health", HealthController, :health)
    get("/healthz", HealthController, :health)
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/runtime/health", RuntimeApiController, :health)
    get("/api/v1/runtime/relay/events", RuntimeApiController, :relay_events)
    post("/api/v1/runtime/projection-preview", RuntimeApiController, :projection_preview)
    get("/api/v1/runtime/:resource", RuntimeApiController, :resource)
    post("/api/v1/linear/webhooks", RuntimeApiController, :linear_webhook)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/health", ObservabilityApiController, :method_not_allowed)
    match(:*, "/healthz", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runtime/health", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runtime/relay/events", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runtime/projection-preview", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/linear/webhooks", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/runs/:issue_id/cancel", ObservabilityApiController, :cancel_run)
    match(:*, "/api/v1/runs/:issue_id/cancel", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/linear/actions", LinearActionController, :execute)
    match(:*, "/api/v1/linear/actions", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runtime/:resource", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
