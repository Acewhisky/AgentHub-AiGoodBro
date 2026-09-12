// Appended in the original collector module's lexical scope by the loader.
// Keep original scan/graph algorithms; prohibit downloaded pointers and shims.
resolvePlatformBinary = function reviewedBundledBinary() {
  const bundled = locateBundledBinary();
  if (!bundled) throw new Error('bundled-scanner-unavailable');
  const reviewed = module.bridgeVendorRoot;
  const real = fs.realpathSync(bundled.path);
  if (!real.startsWith(fs.realpathSync(reviewed) + path.sep)) throw new Error('bundled-scanner-outside-resource');
  return bundled;
};
module.exports.bridgeRunGraph = runTokscaleGraph;
module.exports.bridgeRunUsage = runTokscale;
module.exports.resolvePlatformBinary = resolvePlatformBinary;
