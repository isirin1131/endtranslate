import MarkdownIt from 'markdown-it';

function closingDelimiter(source, delimiter, from) {
  let position = from;
  while ((position = source.indexOf(delimiter, position)) !== -1) {
    let slashes = 0;
    for (let i = position - 1; i >= 0 && source[i] === '\\'; i--) slashes++;
    if (slashes % 2 === 0) return position;
    position += delimiter.length;
  }
  return -1;
}

function mathInline(state, silent) {
  const start = state.pos;
  const source = state.src;
  const opener = ['$$', '\\(', '\\[', '$'].find(marker => source.startsWith(marker, start));
  if (!opener) return false;
  const closer = opener === '\\(' ? '\\)' : opener === '\\[' ? '\\]' : opener;
  const contentStart = start + opener.length;
  if (opener === '$' && /\s/.test(source[contentStart] || ' ')) return false;
  let end = closingDelimiter(source, closer, contentStart);
  if (end === -1 || end === contentStart) return false;
  if (opener === '$') {
    if (/\s/.test(source[end - 1]) || /[0-9]/.test(source[end + 1] || '')) return false;
    if (source.slice(contentStart, end).includes('\n')) return false;
  }
  if (!silent) {
    const token = state.push('math_inline', '', 0);
    token.content = source.slice(contentStart, end);
    token.markup = opener;
    token.meta = { display: opener === '$$' || opener === '\\[' };
  }
  state.pos = end + closer.length;
  return true;
}

function mathBlock(state, startLine, endLine, silent) {
  if (state.sCount[startLine] - state.blkIndent >= 4) return false;
  const start = state.bMarks[startLine] + state.tShift[startLine];
  const rest = state.src.slice(start);
  const environment = rest.match(/^\\begin\{(equation\*?|align\*?|aligned|gather\*?|gathered|multline\*?|alignat\*?)\}/);
  const opener = rest.startsWith('$$') ? '$$' : rest.startsWith('\\[') ? '\\[' : environment?.[0];
  if (!opener) return false;
  const closer = opener === '$$' ? '$$' : opener === '\\[' ? '\\]' : `\\end{${environment[1]}}`;
  const end = closingDelimiter(state.src, closer, start + opener.length);
  if (end === -1) return false;
  let lastLine = startLine;
  while (lastLine < endLine && state.eMarks[lastLine] < end + closer.length) lastLine++;
  if (lastLine >= endLine) return false;
  if (state.src.slice(end + closer.length, state.eMarks[lastLine]).trim()) return false;
  if (silent) return true;
  const token = state.push('math_block', '', 0);
  token.block = true;
  token.map = [startLine, lastLine + 1];
  token.content = environment
    ? state.src.slice(start, end + closer.length)
    : state.src.slice(start + opener.length, end).trim();
  token.meta = { display: true };
  state.line = lastLine + 1;
  return true;
}

export function makeMarkdownParser() {
  const md = new MarkdownIt({ html: false, linkify: false, typographer: false });
  // Recognize math before Markdown's escape/emphasis rules can alter LaTeX.
  md.inline.ruler.before('escape', 'math_inline', mathInline);
  md.block.ruler.before('fence', 'math_block', mathBlock, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
  const renderMath = (tokens, index) => {
    const token = tokens[index];
    const tag = token.block ? 'div' : 'span';
    return `<${tag} class="math-source" data-display="${token.meta.display}" data-tex="${md.utils.escapeHtml(token.content)}"></${tag}>`;
  };
  md.renderer.rules.math_inline = renderMath;
  md.renderer.rules.math_block = renderMath;
  // Translation content cannot cause navigation, image downloads, or HTML execution.
  md.renderer.rules.link_open = () => '<span>';
  md.renderer.rules.link_close = () => '</span>';
  md.renderer.rules.image = (tokens, index) => md.utils.escapeHtml(tokens[index].content);
  return md;
}
