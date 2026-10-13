// Define main function (script entry)
// Clash Verge 订阅挂的 script 增强，安装位置：profiles/<当前订阅 option.script 指向的文件>.js
//
// 1) Codex-Stable 组与规则（merge 源没定义该组时的兜底）。
// 2) 展开 merge 源留下的 prepend-proxies / prepend-proxy-groups / prepend-rules。
//    Verge 在 merge+script 组合下不展开这三个键，mihomo 也不认，不展开就没有 Claude 组和规则，
//    刷新订阅或冷启动后 Claude 流量会落到主代理。这里在 Verge 生成配置时就展开，不等守护来修。
//    节点、组、规则的真相仍只在 merge 源里，本文件不含任何凭据。

function main(config, profileName) {
  if (!config["proxy-groups"]) config["proxy-groups"] = [];
  if (!config["rules"]) config["rules"] = [];

  var GROUP_NAME = "Codex-Stable";

  // Codex-Stable: ordered fallback over the fastest HY2 nodes verified against chatgpt.com,
  // with the subscription's native OpenAI group as the last-resort safety net.
  var codexGroupDef = {
    name: GROUP_NAME,
    type: "fallback",
    proxies: ["SG5-HY2", "SG4-HY2", "JP2-HY2", "JP4-HY2", "JP3-HY2", "TW-2", "TW-4", "TW-7", "OpenAI"],
    url: "https://chatgpt.com/cdn-cgi/trace",
    interval: 600,
    lazy: true
  };

  var hasCodexGroup = false;
  for (var i = 0; i < config["proxy-groups"].length; i++) {
    if (config["proxy-groups"][i] && config["proxy-groups"][i].name === GROUP_NAME) { hasCodexGroup = true; break; }
  }
  if (!hasCodexGroup) config["proxy-groups"].push(codexGroupDef);

  // Prepend Codex/OpenAI rules so they match before the subscription's default OpenAI rule
  var codexRules = [
    "DOMAIN-SUFFIX,chatgpt.com," + GROUP_NAME,
    "DOMAIN-SUFFIX,openai.com," + GROUP_NAME,
    "DOMAIN-SUFFIX,oaistatic.com," + GROUP_NAME,
    "DOMAIN-SUFFIX,oaiusercontent.com," + GROUP_NAME
  ];

  // De-dup: remove any identical rules already present, then prepend
  var existing = config["rules"].filter(function (r) { return codexRules.indexOf(r) === -1; });
  config["rules"] = codexRules.concat(existing);

  // Long-connection tuning
  config["tcp-concurrent"] = true;
  config["unified-delay"] = true;

  expandGuardPrepend(config);

  return config;
}

function expandGuardPrepend(config) {
  var VPS_NAME = "Claude-VPS";
  var MAIN_GROUP = "主代理";
  // Tailscale 的 CGNAT 与 ULA 段不进 TUN（与 claude-ip-heal.sh reload_core 保持一致）
  var TUN_EXCLUDE_ALWAYS = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"];

  var prependProxies = (config["prepend-proxies"] || []).filter(isNamed);
  var prependGroups = (config["prepend-proxy-groups"] || []).filter(isNamed);
  var prependRules = unique(config["prepend-rules"] || []);
  delete config["prepend-proxies"];
  delete config["prepend-proxy-groups"];
  delete config["prepend-rules"];
  if (!prependProxies.length && !prependGroups.length && !prependRules.length) return;

  var proxyNames = nameSet(prependProxies);
  config["proxies"] = prependProxies.concat((config["proxies"] || []).filter(function (p) {
    return !(p && proxyNames[p.name]);
  }));

  // 同名组以 merge 源为准，原位替换；merge 源独有的组放最前
  var groupByName = {};
  prependGroups.forEach(function (g) { groupByName[g.name] = g; });
  var replaced = {};
  var groups = (config["proxy-groups"] || []).map(function (g) {
    if (g && groupByName[g.name]) { replaced[g.name] = true; return groupByName[g.name]; }
    return g;
  });
  config["proxy-groups"] = prependGroups.filter(function (g) { return !replaced[g.name]; }).concat(groups);

  if (proxyNames[VPS_NAME]) {
    config["proxy-groups"].forEach(function (g) {
      if (g && g.name === MAIN_GROUP) {
        g.proxies = [VPS_NAME].concat((g.proxies || []).filter(function (n) { return n !== VPS_NAME; }));
      }
    });
  }

  // 守护出口端点（VPS、家宽）本身必须直连，也不能被 TUN 抓回代理链
  var endpoints = unique(prependProxies.map(function (p) { return String(p.server || ""); }).filter(isIPv4));
  var endpointRules = endpoints.map(function (ip) { return "IP-CIDR," + ip + "/32,DIRECT,no-resolve"; });
  var headRules = unique(endpointRules.concat(prependRules));
  config["rules"] = headRules.concat((config["rules"] || []).filter(function (r) { return headRules.indexOf(r) === -1; }));

  if (config["tun"]) {
    config["tun"]["route-exclude-address"] = unique(
      (config["tun"]["route-exclude-address"] || [])
        .concat(endpoints.map(function (ip) { return ip + "/32"; }))
        .concat(TUN_EXCLUDE_ALWAYS)
    );
  }
}

function isNamed(item) { return !!(item && typeof item === "object" && item.name); }

function isIPv4(text) { return /^\d{1,3}(\.\d{1,3}){3}$/.test(text); }

function nameSet(list) {
  var set = {};
  list.forEach(function (item) { set[item.name] = true; });
  return set;
}

function unique(list) {
  var out = [];
  list.forEach(function (item) { if (out.indexOf(item) === -1) out.push(item); });
  return out;
}
