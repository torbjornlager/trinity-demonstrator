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
  var credentials = config.credentials || 'same-origin';
  if (['omit', 'same-origin', 'include'].indexOf(credentials) < 0)
    throw new Error('Node credentials must be omit, same-origin or include');
  function sessionUrl(path) {
    if (!path) return null;
    return endpoint(path);
  }
  function asset(path) { return new URL(String(path).replace(/^\//, ''), assetBase).href; }
  function endpoint(path) {
    if (!nodeBase) throw new Error('This static demonstrator has no configured remote node');
    if (!/^\/(?!\/)/.test(path)) throw new Error('Node endpoints must be node-relative paths');
    var url = new URL(path.slice(1), nodeBase);
    if (!url.href.startsWith(nodeBase)) throw new Error('Node endpoint escapes the configured service');
    return url.href;
  }
  var remoteNodes = (config.remoteNodes || []).map(function(node) {
    if (['swi', 'trealla', 'gprolog'].indexOf(node.runtime) < 0)
      throw new Error('Remote nodes require an explicit supported runtime');
    return Object.freeze({url:base(node.url), runtime:node.runtime});
  });
  return Object.freeze({
    isStatic: isStatic, assetBase: assetBase, nodeBase: nodeBase,
    credentials: credentials, loginUrl: sessionUrl(config.loginPath), logoutUrl: sessionUrl(config.logoutPath),
    remoteNodes: Object.freeze(remoteNodes),
    discoveryHubUrl: config.discoveryHubUrl ? base(config.discoveryHubUrl).replace(/\/$/, '') : null,
    ownerLogin: config.ownerLogin === true,
    interactionLogging: config.interactionLogging !== false,
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
