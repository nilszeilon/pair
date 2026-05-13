defmodule Pair.HTTPServer do
  @moduledoc """
  REST API for the pi session orchestrator.
  Serves a browse page on GET / for browsers and JSON for API clients.
  """

  use Plug.Router

  require Logger
  defp debug?, do: System.get_env("PAIR_DEBUG") == "1"

  plug(:match)
  plug(:fetch_query_params)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # List all sessions (HTML browse page for browsers, JSON for API clients)
  get "/" do
    sessions = list_sessions()

    if html_client?(conn) do
      if debug?(), do: Logger.debug("GET / → HTML (sessions=#{length(sessions)})")
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, browse_html(sessions))
    else
      if debug?(), do: Logger.debug("GET / → JSON (sessions=#{length(sessions)})")
      send_resp(conn, 200, Jason.encode!(sessions, pretty: true))
    end
  end

  # Always-JSON sessions endpoint (for JS auto-refresh)
  get "/sessions" do
    sessions = list_sessions()
    if debug?(), do: Logger.debug("GET /sessions → #{length(sessions)} sessions")
    send_resp(conn, 200, Jason.encode!(sessions, pretty: true))
  end

  # Start a session with server-assigned incremental ID
  post "/sessions" do
    {:ok, body, conn} = read_body(conn)
    id = Pair.Counter.next()
    if debug?(), do: Logger.info("POST /sessions id=#{id} body=#{String.slice(body, 0, 200)}")
    {root_path, env, agent} =
      case Jason.decode(body) do
        {:ok, %{"root_path" => path} = params} ->
          env = Map.get(params, "env", %{})
          host = Map.get(params, "host", "")
          env = if host != "", do: Map.put(env, "HOST", host), else: env
          {resolve_path(path), env, Map.get(params, "agent", "pi")}
        _ -> {File.cwd!(), %{}, "pi"}
      end

    case start_session(id, root_path, env, agent) do
      {:ok, _pid} ->
        state = Pair.SessionServer.get_state(id)
        send_resp(conn, 201, Jason.encode!(Map.merge(%{status: "started"}, state), pretty: true))

      {:error, {:already_started, _pid}} ->
        state = Pair.SessionServer.get_state(id)
        send_resp(conn, 200, Jason.encode!(Map.merge(%{status: "already_running"}, state), pretty: true))

      {:error, reason} ->
        send_resp(conn, 500, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  # Start a new session
  post "/session/:id/start" do
    {:ok, body, conn} = read_body(conn)
    require Logger
    if debug?(), do: Logger.info("POST /session/#{id}/start body=#{String.slice(body, 0, 200)}")
    {root_path, env, agent} =
      case Jason.decode(body) do
        {:ok, %{"root_path" => path} = params} ->
          env = Map.get(params, "env", %{})
          host = Map.get(params, "host", "")
          env = if host != "", do: Map.put(env, "HOST", host), else: env
          {resolve_path(path), env, Map.get(params, "agent", "pi")}
        _ -> {File.cwd!(), %{}, "pi"}
      end

    case start_session(id, root_path, env, agent) do
      {:ok, _pid} ->
        state = Pair.SessionServer.get_state(id)
        send_resp(conn, 201, Jason.encode!(Map.merge(%{status: "started"}, state), pretty: true))

      {:error, {:already_started, _pid}} ->
        state = Pair.SessionServer.get_state(id)
        send_resp(conn, 200, Jason.encode!(Map.merge(%{status: "already_running"}, state), pretty: true))

      {:error, reason} ->
        send_resp(conn, 500, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  # Get session state
  get "/session/:id" do
    state = Pair.SessionServer.get_state(id)
    send_resp(conn, 200, Jason.encode!(state, pretty: true))
  end

  # Stop a session
  delete "/session/:id" do
    Pair.SessionServer.stop(id)
    send_resp(conn, 200, Jason.encode!(%{status: "stopped", session_id: id}))
  end

  # Browse server filesystem for path selection
  get "/browse" do
    path = conn.params["path"] || System.user_home!()
    if debug?(), do: Logger.debug("GET /browse raw_path=#{path}")
    path = resolve_path(path)
    if debug?(), do: Logger.debug("GET /browse resolved=#{path}")
    entries = browse_dir(path)
    if debug?(), do: Logger.debug("GET /browse entries=#{length(entries)}")
    send_resp(conn, 200, Jason.encode!(%{path: path, entries: entries}))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end

  def start_session(id, root_path, env \\ %{}, agent \\ "pi") do
    DynamicSupervisor.start_child(
      Pair.SessionSupervisor,
      {Pair.SessionServer, id: id, root_path: root_path, env: env, agent: agent}
    )
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp list_sessions do
    Pair.SessionRegistry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(fn id ->
      Pair.SessionServer.get_state(id)
    end)
  end

  # Resolve paths: absolute paths stay as-is, ~ expands, relative resolves from home
  defp resolve_path(path) do
    home = System.user_home!()
    cond do
      path == "~" -> home
      String.starts_with?(path, "~/") -> home <> String.replace_leading(path, "~", "")
      String.starts_with?(path, "/") -> path
      true -> Path.join(home, path)
    end
  end

  defp browse_dir(path) do
    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(fn f -> not String.starts_with?(f, ".") end)
        |> Enum.sort_by(&String.downcase/1)
        |> Enum.map(fn f ->
          full = Path.join(path, f)
          type = if File.dir?(full), do: "dir", else: "file"
          %{name: f, type: type}
        end)
      {:error, _} -> []
    end
  end

  defp html_client?(conn) do
    accept = Plug.Conn.get_req_header(conn, "accept") |> List.first() || ""
    String.contains?(accept, "text/html")
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, h} -> List.to_string(h)
      _ -> "localhost"
    end
  end

  defp browse_html(sessions) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Pair — Sessions</title>
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body {
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        background: #1a1a1a;
        color: #e0e0e0;
        padding: 24px;
        max-width: 800px;
        margin: 0 auto;
      }
      h1 { font-size: 1.6rem; margin-bottom: 8px; }
      .subtitle { color: #888; font-size: 0.85rem; margin-bottom: 24px; }

      .new-session {
        background: #252525;
        border: 1px solid #333;
        border-radius: 10px;
        padding: 18px 20px;
        margin-bottom: 28px;
      }
      .new-session h2 { font-size: 1.05rem; margin-bottom: 12px; color: #aaa; }
      .new-session form { display: flex; gap: 10px; flex-wrap: wrap; align-items: flex-end; }
      .new-session .field { display: flex; flex-direction: column; gap: 4px; }
      .new-session label { font-size: 0.78rem; color: #999; }
      .new-session input {
        background: #1a1a1a;
        border: 1px solid #444;
        border-radius: 6px;
        color: #e0e0e0;
        padding: 8px 12px;
        font-size: 0.9rem;
        outline: none;
      }
      .new-session input:focus { border-color: #6cf; }
      .new-session button {
        background: #365;
        border: 1px solid #4a7;
        color: #d0ffd0;
        border-radius: 6px;
        padding: 8px 18px;
        font-size: 0.9rem;
        cursor: pointer;
        font-weight: 600;
      }
      .new-session button:hover { background: #3a7; }

      .session-list { display: flex; flex-direction: column; gap: 10px; }
      .session-card {
        background: #252525;
        border: 1px solid #333;
        border-radius: 10px;
        padding: 16px 18px;
        display: flex;
        justify-content: space-between;
        align-items: center;
        gap: 12px;
        flex-wrap: wrap;
      }
      .session-card .info { flex: 1; min-width: 0; }
      .session-card .name { font-weight: 700; font-size: 1rem; margin-bottom: 3px; }
      .session-card .meta {
        font-size: 0.78rem;
        color: #888;
        display: flex;
        gap: 12px;
        flex-wrap: wrap;
      }
      .status {
        display: inline-block;
        width: 8px;
        height: 8px;
        border-radius: 50%;
        margin-right: 4px;
      }
      .status.alive { background: #4c6; box-shadow: 0 0 6px #4c6; }
      .status.dead { background: #c44; }
      .session-card a {
        color: #6cf;
        text-decoration: none;
        font-size: 0.85rem;
        font-weight: 600;
        white-space: nowrap;
        padding: 6px 14px;
        border: 1px solid #356;
        border-radius: 6px;
        background: #1a2a2a;
      }
      .session-card a:hover { background: #1e3a3a; border-color: #6cf; }

      .empty { text-align: center; color: #666; padding: 40px 0; font-size: 0.95rem; }
      .footer {
        margin-top: 32px;
        text-align: center;
        font-size: 0.72rem;
        color: #555;
      }

      @media (max-width: 500px) {
        body { padding: 14px; }
        .new-session form { flex-direction: column; }
        .new-session input { width: 100% !important; }
        .session-card { flex-direction: column; align-items: flex-start; }
      }

      /* Browse modal */
      .modal {
        position: fixed; top: 0; left: 0; width: 100%; height: 100%;
        background: rgba(0,0,0,0.7);
        display: flex; align-items: center; justify-content: center;
        z-index: 100;
      }
      .modal-content {
        background: #252525;
        border: 1px solid #444;
        border-radius: 12px;
        width: 90%; max-width: 550px; max-height: 70vh;
        display: flex; flex-direction: column;
        overflow: hidden;
      }
      .modal-header {
        display: flex; justify-content: space-between; align-items: center;
        padding: 14px 18px; border-bottom: 1px solid #333;
        font-size: 0.9rem; color: #6cf;
      }
      .modal-header button {
        background: none; border: none; color: #888; font-size: 1.3rem;
        cursor: pointer; padding: 0 4px;
      }
      .modal-header button:hover { color: #fff; }
      .modal-body {
        flex: 1; overflow-y: auto; padding: 8px 0;
      }
      .browse-entry {
        display: flex; align-items: center; gap: 8px;
        padding: 8px 18px; cursor: pointer;
        font-size: 0.88rem; border: none; background: none; color: #ccc;
        width: 100%; text-align: left;
      }
      .browse-entry:hover { background: #303030; }
      .browse-entry .icon { font-size: 0.85rem; width: 18px; text-align: center; }
      .browse-entry.file { color: #777; cursor: default; }
      .browse-entry.file:hover { background: transparent; }
      .modal-footer {
        display: flex; gap: 8px; padding: 12px 18px; border-top: 1px solid #333;
      }
      .modal-footer button {
        padding: 6px 14px; border-radius: 6px; font-size: 0.82rem;
        cursor: pointer; border: 1px solid #444; background: #333; color: #ccc;
      }
      .modal-footer button.primary { background: #365; border-color: #4a7; color: #d0ffd0; }
      .modal-footer button:hover { opacity: 0.85; }
      .browse-empty { padding: 30px 18px; text-align: center; color: #666; font-size: 0.85rem; }
    </style>
    </head>
    <body>
    <h1>Pair Sessions</h1>
    <p class="subtitle">Active sessions on #{hostname()}</p>

    <div class="new-session">
      <h2>+ New Session</h2>
      <form id="new-session-form">
        <div class="field">
          <label for="agent">Agent</label>
          <input id="agent" name="agent" value="pi" placeholder="pi" style="width: 120px;">
        </div>
        <div class="field" style="flex: 1; min-width: 200px;">
          <label for="root_path">Project path</label>
          <div style="display: flex; gap: 6px;">
            <input id="root_path" name="root_path" value="~" placeholder="~/dev/myproject" style="flex: 1;">
            <button type="button" id="browse-btn" style="background:#333;border-color:#555;color:#ccc;padding:8px 12px;cursor:pointer;">Browse</button>
          </div>
        </div>
        <button type="submit">Start</button>
      </form>
    </div>

    <div id="browse-modal" class="modal" style="display:none;">
      <div class="modal-content">
        <div class="modal-header">
          <span id="browse-path">/</span>
          <button onclick="closeBrowse()">&times;</button>
        </div>
        <div class="modal-body" id="browse-entries"></div>
        <div class="modal-footer">
          <button class="primary" onclick="selectBrowseDir()">Select</button>
          <button onclick="navigateBrowse('~')">Home</button>
          <button onclick="navigateBrowse('/')">Root</button>
          <button onclick="navigateBrowse('..')">Up</button>
        </div>
      </div>
    </div>

    <div class="session-list" id="session-list">
      #{render_sessions(sessions)}
    </div>

    <p class="footer">Auto-refreshes every 5s</p>

    <script>
      function esc(s) {
        return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
      }
      function sessionCard(s) {
        const alive = s.pi_alive !== false;
        const cls = alive ? 'alive' : 'dead';
        const label = alive ? 'live' : 'stopped';
        const started = s.started_at ? new Date(s.started_at).toLocaleString() : '-';
        return '<div class="session-card">' +
          '<div class="info">' +
            '<div class="name">' + esc(s.id) + '</div>' +
            '<div class="meta">' +
              '<span><span class="status ' + cls + '"></span>' + label + '</span>' +
              '<span>agent: ' + esc(s.agent || '?') + '</span>' +
              '<span>started: ' + started + '</span>' +
            '</div>' +
          '</div>' +
          '<a href="' + esc(s.url) + '" target="_blank">Open &#8594;</a>' +
        '</div>';
      }
      async function refresh() {
        try {
          const r = await fetch('/sessions');
          if (!r.ok) return;
          const sessions = await r.json();
          const list = document.getElementById('session-list');
          list.innerHTML = sessions.length === 0
            ? '<div class="empty"><p>No active sessions.</p><p>Start one above</p></div>'
            : sessions.map(sessionCard).join('');
        } catch (_) {}
      }

      // ── New session form ─────────────────────────────────
      document.getElementById('new-session-form').addEventListener('submit', async function(e) {
        e.preventDefault();
        const agent = document.getElementById('agent').value || 'pi';
        const raw = document.getElementById('root_path').value || '~';
        try {
          const r = await fetch('/sessions', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ root_path: raw, agent: agent, env: {} })
          });
          if (r.ok) {
            refresh();
          } else {
            alert('Failed to start session');
          }
        } catch (err) {
          alert('Error: ' + err.message);
        }
      });
      setInterval(refresh, 5000);

      // ── File browser ──────────────────────────────────────
      var browseDir = '';
      document.getElementById('browse-btn').addEventListener('click', function() {
        browseDir = document.getElementById('root_path').value || '~';
        openBrowse(browseDir);
      });
      function openBrowse(dir) {
        document.getElementById('browse-modal').style.display = 'flex';
        loadBrowse(dir);
      }
      function closeBrowse() {
        document.getElementById('browse-modal').style.display = 'none';
      }
      async function loadBrowse(dir) {
        try {
          var r = await fetch('/browse?path=' + encodeURIComponent(dir));
          var data = await r.json();
          browseDir = data.path;
          document.getElementById('browse-path').textContent = data.path;
          var body = document.getElementById('browse-entries');
          if (data.entries.length === 0) {
            body.innerHTML = '<div class="browse-empty">Empty directory</div>';
            return;
          }
          var dirs = [];
          var files = [];
          for (var i = 0; i < data.entries.length; i++) {
            if (data.entries[i].type === 'dir') dirs.push(data.entries[i]);
            else files.push(data.entries[i]);
          }
          var html = '';
          for (var d = 0; d < dirs.length; d++) {
            html += '<button class="browse-entry" data-dir="' + esc(dirs[d].name) + '"><span class="icon">&#x1F4C1;</span>' + esc(dirs[d].name) + '</button>';
          }
          for (var f = 0; f < files.length; f++) {
            html += '<div class="browse-entry file"><span class="icon">&#x1F4C4;</span>' + esc(files[f].name) + '</div>';
          }
          body.innerHTML = html;
          // Event delegation for directory clicks
          var buttons = body.querySelectorAll('.browse-entry[data-dir]');
          for (var b = 0; b < buttons.length; b++) {
            buttons[b].addEventListener('click', function() {
              navigateBrowse(this.getAttribute('data-dir'));
            });
          }
        } catch (_) {}
      }
      function navigateBrowse(to) {
        if (to === '~') { loadBrowse('~'); return; }
        if (to === '..') {
          var parts = browseDir.split('/').filter(Boolean);
          parts.pop();
          loadBrowse('/' + parts.join('/'));
          return;
        }
        loadBrowse(browseDir.replace(/[/]$/, '') + '/' + to);
      }
      function selectBrowseDir() {
        document.getElementById('root_path').value = browseDir;
        closeBrowse();
      }
      document.getElementById('browse-modal').addEventListener('click', function(e) {
        if (e.target === this) closeBrowse();
      });
    </script>
    </body>
    </html>
    """
  end

  defp render_sessions([]) do
    ~s(<div class="empty"><p>No active sessions.</p><p>Start one above ^</p></div>)
  end

  defp render_sessions(sessions) do
    sessions
    |> Enum.map(fn s ->
      alive = s[:pi_alive] != false
      status_class = if alive, do: "alive", else: "dead"
      label = if alive, do: "live", else: "stopped"

      started =
        case s[:started_at] do
          nil -> "\u2014"
          ts ->
            case DateTime.from_iso8601(ts) do
              {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
              _ -> ts
            end
        end

      """
      <div class="session-card">
        <div class="info">
          <div class="name">#{escape_html(s[:id] || "?")}</div>
          <div class="meta">
            <span><span class="status #{status_class}"></span>#{label}</span>
            <span>agent: #{escape_html(s[:agent] || "?")}</span>
            <span>started: #{escape_html(started)}</span>
          </div>
        </div>
        <a href="#{escape_html(s[:url] || "#")}" target="_blank">Open \u2192</a>
      </div>
      """
    end)
    |> Enum.join("\n")
  end

  defp escape_html(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_html(other), do: escape_html(to_string(other))
end
