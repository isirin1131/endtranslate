window.mathJaxReady = new Promise((resolve, reject) => {
window.MathJax = {
  loader: {
    paths: { mathjax: new URL('./vendor/mathjax', document.baseURI).href },
    load: ['[tex]/begingroup', '[tex]/cancel', '[tex]/mathtools', '[tex]/braket', '[tex]/boldsymbol', '[tex]/color'],
    failed(error) { reject(new Error(error.message || '内置数学组件加载失败')); }
  },
  tex: {
    packages: {
      '[-]': ['autoload', 'require', 'noundefined', 'noerrors'],
      '[+]': ['begingroup', 'cancel', 'mathtools', 'braket', 'boldsymbol', 'color']
    },
    maxBuffer: 32768,
    tags: 'none',
    formatError(_jax, error) { throw error; }
  },
  svg: { fontCache: 'none' },
  options: {
    enableMenu: false,
    enableExplorer: false,
    enableExplorerHelp: false,
    enableEnrichment: false,
    enableComplexity: false,
    enableSpeech: false,
    enableBraille: false
  },
  startup: {
    typeset: false,
    ready() {
      try {
        MathJax.startup.defaultReady();
        MathJax.startup.promise.then(resolve, reject);
      } catch (error) { reject(error); }
    }
  }
};
});
// Keep a load error available for the native caller without an unhandled rejection.
window.mathJaxReady.catch(() => {});
