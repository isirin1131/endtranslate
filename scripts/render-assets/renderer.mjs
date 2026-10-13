import { makeMarkdownParser } from './markdown.mjs';

const markdown = makeMarkdownParser();

window.EndTranslate = {
  async render(source, width, fontSize) {
    await window.mathJaxReady;
    MathJax.typesetClear();
    MathJax.texReset();
    // Reset user-defined macros between translations, including global definitions.
    MathJax.tex2mml('\\begingroupSandbox', { display: false });
    const root = document.getElementById('translation');
    root.style.width = `${width}px`;
    root.style.fontSize = `${fontSize}px`;
    root.innerHTML = markdown.render(source);
    const formulas = [...root.querySelectorAll('.math-source')];
    let errors = 0;
    for (const formula of formulas) {
      const latex = formula.dataset.tex;
      const display = formula.dataset.display === 'true';
      try {
        // The complete TeX font and allowed extensions are already loaded locally.
        const output = MathJax.tex2svg(latex, {
          display, em: fontSize, ex: fontSize * 0.5, containerWidth: width - 8
        });
        if (output.querySelector('[data-mjx-error], [data-mml-node="merror"]')) throw new Error('Invalid formula');
        formula.replaceChildren(output);
      } catch {
        errors++;
        formula.classList.add('math-error');
        formula.textContent = display ? `$$\n${latex}\n$$` : `$${latex}$`;
        formula.title = '此公式暂无法排版，已保留 LaTeX 源码';
      }
    }
    await document.fonts.ready;
    // Keep wide formulas inside the selected column; SVG remains vector at every scale.
    for (const svg of root.querySelectorAll('mjx-container > svg')) {
      const box = svg.getBoundingClientRect();
      const available = width - 8;
      if (box.width > available) {
        svg.style.width = `${available}px`;
        svg.style.height = `${box.height * available / box.width}px`;
      }
    }
    const height = Math.max(16, Math.ceil(root.getBoundingClientRect().height));
    return { height, formulas: formulas.length, errors };
  }
};
