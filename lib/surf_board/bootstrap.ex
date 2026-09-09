defmodule SurfBoard.Bootstrap do
  @moduledoc false
  # Shared browser-side bootstrap JS for push-based element finding.
  #
  # The body installs window.__w with an opcode interpreter, MutationObserver,
  # LiveView onPatchEnd hook, and query checker. It references `__surfboard`
  # as a free variable — the caller provides it as either:
  #   - CDP: a global binding via Runtime.addBinding
  #   - BiDi: a channel callback via script.addPreloadScript argument
  #
  # Source of truth lives in priv/surf_board.js. We read it at compile time
  # via @external_resource so edits to the .js file trigger a recompile,
  # and the string is baked into the BEAM (no runtime FS reads).

  # Prefer the minified bundle when present (committed to repo via
  # `mix surf_board.minify`). Falls back to the readable source so dev
  # edits to surf_board.js take effect without a rebuild step. Both
  # paths are listed as @external_resource so Mix recompiles on
  # either change.
  @bootstrap_min_path Path.join([__DIR__, "..", "..", "priv", "surf_board.min.js"])
  @bootstrap_src_path Path.join([__DIR__, "..", "..", "priv", "surf_board.js"])
  @external_resource @bootstrap_min_path
  @external_resource @bootstrap_src_path
  @body (case File.read(@bootstrap_min_path) do
           {:ok, content} -> content
           _ -> File.read!(@bootstrap_src_path)
         end)

  @doc """
  CDP form: IIFE that assumes `__surfboard` is a global binding.

  `live_view_aware?` gates the LiveView `onPatchEnd` hook inside the
  bootstrap body (see priv/surf_board.js's `detectReady`/`installLvHook`)
  — false by default, so a plain scraping/automation session never
  activates LiveView-patch tracking, even on a LiveView page.
  """
  def cdp_iife(live_view_aware? \\ false) do
    "(function() {\nvar __surfboardLiveViewAware = #{live_view_flag(live_view_aware?)};\n" <>
      @body <> "\n})()"
  end

  @doc "BiDi form: arrow function receiving `__surfboard` as channel parameter."
  def bidi_preload(live_view_aware? \\ false) do
    "(__surfboard) => {\nvar __surfboardLiveViewAware = #{live_view_flag(live_view_aware?)};\n" <>
      @body <> "\n}"
  end

  defp live_view_flag(flag), do: Jason.encode!(!!flag)

  @doc """
  Build a JS expression that calls `window.__w.registerQuery(id, ops,
  count, root)`. Called from CDPClient and BiDiClient find paths.

  `root_js` is `"this"` for scoped (Element parent) or `"null"` for document.
  Bootstrap must be installed before this runs — install_bootstrap
  guarantees that, so there's no fallback path.
  """
  def register_js(query_id, ops_json, count_js, root_js \\ "null") do
    id_js = Jason.encode!(query_id)

    # Hot path: bootstrap is installed → delegate to W.registerQuery,
    # which lives in priv/surf_board.js.
    # Cold path: no bootstrap yet (e.g. find runs on about:blank before
    # any navigation has loaded the preload script). Inline a minimal
    # querySelectorAll + binding push so the caller still gets a
    # syntax error surfaced via the binding event.
    "var W=window.__w;" <>
      "if(W){W.registerQuery(#{id_js},#{ops_json},#{count_js},#{root_js});}" <>
      "else{try{" <>
      "var r={els:[],error:null};" <>
      "try{var _o=#{ops_json};for(var i=0;i<_o.length;i++){var o=_o[i];if(o[0]==='query'){r.els=Array.from(document.querySelectorAll(o[2]));}}}catch(e){r.error=e.message;}" <>
      "if(r.error)__surfboard(JSON.stringify({id:#{id_js},count:0,error:r.error}));" <>
      "else{var c=r.els.length;var m=#{count_js}===null?c>0:c===#{count_js};if(m)__surfboard(JSON.stringify({id:#{id_js},count:c}));}" <>
      "}catch(e){}}"
  end

  @doc "JS to clean up a resolved query from window.__w.queries."
  def cleanup_js(query_id) do
    id_js = Jason.encode!(query_id)
    "if(window.__w)window.__w.cleanupQuery(#{id_js});"
  end
end
