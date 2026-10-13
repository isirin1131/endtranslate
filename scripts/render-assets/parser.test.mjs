import test from 'node:test';
import assert from 'node:assert/strict';
import { makeMarkdownParser } from './markdown.mjs';

const md = makeMarkdownParser();
function mathTokens(source) {
  return md.parse(source, {}).flatMap(token => token.children || [token])
    .filter(token => token.type === 'math_inline' || token.type === 'math_block');
}

test('LaTeX survives Markdown escapes and emphasis in all four delimiters', () => {
  const source = String.raw`中文 $x_1 + \frac{a}{b}$ 和 \(A_{i,j}\) 后文

$$
\sum_{i=1}^{n} x_i
$$

\[\int_0^1 f(x)\,dx\]`;
  assert.deepEqual(mathTokens(source).map(t => t.content), [
    String.raw`x_1 + \frac{a}{b}`, String.raw`A_{i,j}`,
    String.raw`\sum_{i=1}^{n} x_i`, String.raw`\int_0^1 f(x)\,dx`
  ]);
});

test('code, escaped dollars and currency stay literal', () => {
  const source = '`$x^2$` and \\$5, from $5 to $10.\n\n```latex\n$$x^2$$\n```';
  assert.equal(mathTokens(source).length, 0);
  assert.match(md.render(source), /<code>\$x\^2\$<\/code>/);
});

test('display environments and formulas in lists and tables retain their source', () => {
  const source = String.raw`- 条目 $x_1$

| 含义 | 公式 |
| --- | --- |
| 均值 | $\mu$ |

\begin{align}
a &= b + c \\
d &= e
\end{align}`;
  const tokens = mathTokens(source);
  assert.equal(tokens.length, 3);
  assert.equal(tokens[1].content, String.raw`\mu`);
  assert.ok(tokens[2].content.startsWith(String.raw`\begin{align}`));
  assert.match(md.render(source), /<table>/);
});

test('unclosed math does not swallow following paragraphs', () => {
  const html = md.render('Before $x + 1\n\nAfter **visible**');
  assert.match(html, /Before \$x \+ 1/);
  assert.match(html, /After <strong>visible<\/strong>/);
  assert.equal(mathTokens('$$\nunclosed').length, 0);
});

test('translation HTML, links and images cannot create active content', () => {
  const html = md.render('<script>throw Error("unsafe")</script>\n\n![diagram](https://example.invalid/image.png) [reference](https://example.invalid/)');
  assert.ok(!html.includes('<script>'));
  assert.ok(!html.includes('<img'));
  assert.ok(!html.includes('<a '));
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /diagram/);
  assert.match(html, /reference/);
  assert.ok(!html.includes('https://'));
});

test('formula attributes escape HTML without rewriting LaTeX', () => {
  const source = String.raw`$\text{"<tag>&"}$`;
  assert.equal(mathTokens(source)[0].content, String.raw`\text{"<tag>&"}`);
  const html = md.render(source);
  assert.ok(!html.includes('<tag>'));
  assert.ok(html.includes('&quot;&lt;tag&gt;&amp;&quot;'));
});
