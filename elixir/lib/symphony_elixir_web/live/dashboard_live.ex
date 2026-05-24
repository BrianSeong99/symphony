defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Private runtime console for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.RuntimeConsole.Api
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:runtime_console, load_runtime_console())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:runtime_console, load_runtime_console())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Runtime Console
            </p>
            <h1 class="hero-title">
              Private Automation Kernel
            </h1>
            <p class="hero-copy">
              Agents, queues, dependency gates, relay policy, and private runtime memory for unattended Symphony operation.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <nav class="runtime-nav" aria-label="Runtime console views">
          <a :for={view <- runtime_views()} href={view.href} class="runtime-nav-item">
            <span class="runtime-nav-label"><%= view.label %></span>
            <span class="runtime-nav-detail"><%= view.detail %></span>
          </a>
        </nav>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Runtime console</h2>
              <p class="section-copy">Local Symphony state is canonical; Linear and GitHub are downstream surfaces.</p>
            </div>
          </div>

          <div class="runtime-panel-grid">
            <article class="runtime-panel">
              <p class="runtime-panel-label">Projects</p>
              <p class="runtime-panel-value numeric"><%= @runtime_console.projects.count %></p>
              <p class="runtime-panel-copy">Outcome projects from the central operating model.</p>
            </article>

            <article class="runtime-panel">
              <p class="runtime-panel-label">Policies</p>
              <p class="runtime-panel-value numeric"><%= length(@runtime_console.policies.projection_templates) %></p>
              <p class="runtime-panel-copy">Projection templates and field ownership profiles.</p>
            </article>

            <article class="runtime-panel">
              <p class="runtime-panel-label">Relay events</p>
              <p class="runtime-panel-value numeric"><%= @runtime_console.relay_events.count %></p>
              <p class="runtime-panel-copy">Linear/GitHub relay activity kept inside Symphony.</p>
            </article>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Project connections</h2>
              <p class="section-copy">Linear projects map to outcomes; repos stay metadata or downstream links.</p>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table" style="min-width: 780px;">
              <thead>
                <tr>
                  <th>Outcome</th>
                  <th>Domain</th>
                  <th>Linear</th>
                  <th>Sync</th>
                  <th>Repo metadata</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={project <- Enum.take(@runtime_console.projects.projects, 6)}>
                  <td><span class="issue-id"><%= project.name %></span></td>
                  <td><%= project.operating_domain %></td>
                  <td class="mono"><%= project.linear_project_key %></td>
                  <td><span class="state-badge"><%= project.sync_profile %></span></td>
                  <td><%= repo_metadata_summary(project.repo_metadata) %></td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Private Symphony state</h2>
              <p class="section-copy">Workpads, agent memory, and private notes stay inside Symphony.</p>
            </div>
          </div>

          <%= if @runtime_console.issues.items == [] do %>
            <p class="empty-state">No local runtime issue records are attached to this console snapshot.</p>
          <% else %>
            <div class="private-state-grid">
              <article :for={issue <- @runtime_console.issues.items} class="private-state-panel">
                <div class="private-state-header">
                  <div>
                    <p class="runtime-panel-label">Issue</p>
                    <h3 class="private-state-title"><%= runtime_issue_title(issue) %></h3>
                  </div>
                  <div class="link-row">
                    <a :for={link <- external_link_items(issue)} href={link.href} class="link-chip"><%= link.label %></a>
                  </div>
                </div>

                <div class="private-state-columns">
                  <div>
                    <p class="runtime-panel-label">Workpad</p>
                    <p class="private-state-copy"><%= map_get(issue, :workpad) || "Private workpad unavailable." %></p>
                  </div>
                  <div>
                    <p class="runtime-panel-label">Agent memory</p>
                    <p class="private-state-copy"><%= map_get(issue, :agent_memory) || "No active memory snapshot." %></p>
                  </div>
                </div>

                <pre class="code-panel projection-panel"><%= pretty_value(map_get(issue, :projection_decisions, %{})) %></pre>
              </article>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Runner ownership</h2>
              <p class="section-copy">Single-owner guard for polling, dispatch, and unattended merge work.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(Map.get(@payload, :runner)) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_runtime_console do
    opts = [runtime_state: Endpoint.config(:runtime_console_state) || %{}]

    %{
      health: Api.health(opts),
      projects: Api.projects(opts),
      policies: Api.policies(opts),
      issues: Api.resource(:issues, opts),
      relay_events: Api.resource(:relay_events, opts)
    }
  end

  defp runtime_views do
    [
      %{label: "Runs", detail: "active work", href: "/api/v1/runtime/runs"},
      %{label: "Agents", detail: "sessions", href: "/api/v1/runtime/agents"},
      %{label: "Dependency Graph", detail: "DAG gates", href: "/api/v1/runtime/dependencies"},
      %{label: "Blocked", detail: "checkpoints", href: "/api/v1/runtime/checkpoints"},
      %{label: "Reviews", detail: "repair loop", href: "/api/v1/runtime/reviews"},
      %{label: "Policies", detail: "projection", href: "/api/v1/runtime/policies"},
      %{label: "Relay", detail: "events", href: "/api/v1/runtime/relay/events"},
      %{label: "Simulation", detail: "safety", href: "/api/v1/runtime/projection-preview"},
      %{label: "Learning", detail: "rules", href: "/api/v1/runtime/policies"},
      %{label: "Research", detail: "corpus", href: "/api/v1/runtime/policies"},
      %{label: "Health", detail: "service", href: "/api/v1/runtime/health"},
      %{label: "Settings", detail: "config", href: "/api/v1/runtime/projects"}
    ]
  end

  defp runtime_issue_title(issue), do: map_get(issue, :title) || map_get(issue, :identifier) || map_get(issue, :id) || "Untitled"

  defp external_link_items(issue) do
    [
      {:linear_url, "Linear"},
      {:github_issue_url, "GitHub issue"},
      {:github_pr_url, "GitHub PR"}
    ]
    |> Enum.flat_map(fn {key, label} ->
      case map_get(issue, key) do
        href when is_binary(href) and href != "" -> [%{label: label, href: href}]
        _ -> []
      end
    end)
  end

  defp repo_metadata_summary(metadata) when is_map(metadata) do
    metadata
    |> map_get(:labels, [])
    |> Enum.join(", ")
    |> case do
      "" -> map_get(metadata, :representation, "metadata")
      labels -> labels
    end
  end

  defp repo_metadata_summary(_metadata), do: "metadata"

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
