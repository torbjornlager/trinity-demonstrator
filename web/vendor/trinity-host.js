/* The UI's file location and execution service are separate deployment inputs. */
(function(root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory;
  else root.TrinityHost = factory(root.WEB_PROLOG_HOST || {}, root.location);
}(typeof window !== 'undefined' ? window : this, function(config, location) {
  'use strict';
  var isStatic = config.mode === 'static';
  function base(value) {
    var url = new URL(value, location.href);
    if (!/^https?:$/.test(url.protocol) || url.username || url.password || url.search || url.hash)
      throw new Error('Host URLs must be HTTP(S) URLs without credentials, query or fragment');
    if (location.protocol === 'https:' && url.protocol !== 'https:')
      throw new Error('An HTTPS demonstrator requires HTTPS node and asset URLs');
    url.pathname = url.pathname.replace(/\/?$/, '/');
    return url.href;
  }
  var assetBase = base(config.assetBase || '/');
  var nodeBase = config.nodeUrl ? base(config.nodeUrl) : isStatic ? null : base(location.origin);
  function asset(path) { return new URL(String(path).replace(/^\//, ''), assetBase).href; }
  function endpoint(path) {
    if (!nodeBase) throw new Error('This static demonstrator has no configured remote node');
    if (!/^\/(?!\/)/.test(path)) throw new Error('Node endpoints must be node-relative paths');
    return new URL(path.slice(1), nodeBase).href;
  }
  return Object.freeze({
    isStatic: isStatic, assetBase: assetBase, nodeBase: nodeBase,
    defaultNode: isStatic && !nodeBase ? 'swi-wasm' : null,
    asset: asset, endpoint: endpoint,
    websocket: function() {
      var url = new URL(endpoint('/ws'));
      url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
      return url.href;
    },
    runtimeAssets: function() {
      return isStatic ? Object.freeze({workerUrl:asset('swi_wasm_actor_worker.js'), engineUrl:asset('swipl-bundle.js'),
        prologBaseUrl:asset('wasm/'), sharedDatabaseUrl:asset('wasm/shared_db.pl')}) : null;
    }
  });
}));
