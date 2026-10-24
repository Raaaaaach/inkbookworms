const app = document.getElementById("app");
const PASS_KEY = "bookworms.password";

const covers = [
  ["sunset", "日落"],
  ["sea", "海"],
  ["ink", "墨"],
  ["moss", "苔"],
  ["gold", "金"],
  ["night", "夜"],
];

function route() {
  const hash = location.hash.replace(/^#/, "") || "/";
  const parts = hash.split("/").filter(Boolean);
  return { hash, parts };
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function paragraphs(text) {
  const chunks = String(text || "").trim().split(/\n\s*\n/);
  if (!chunks.filter(Boolean).length) {
    return "<p class=\"muted\">这一章还是空白。</p>";
  }
  return chunks.map((chunk) => `<p>${escapeHtml(chunk).replace(/\n/g, "<br>")}</p>`).join("");
}

function password() {
  return sessionStorage.getItem(PASS_KEY) || "";
}

function headers(extra) {
  const result = { "Content-Type": "application/json", ...(extra || {}) };
  const secret = password();
  if (secret) result["X-Author-Password"] = secret;
  return result;
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: headers(options.headers),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.error || "请求失败");
  }
  return data;
}

function topbar(active) {
  return `
    <header class="topbar">
      <a class="brand" href="#/">
        <strong>Ink Bookworms</strong>
        <span>写给愿意停下来的人</span>
      </a>
      <nav class="nav">
        <a class="${active === "library" ? "active" : ""}" href="#/">书库</a>
        <a class="${active === "studio" ? "active" : ""}" href="#/studio">写作室</a>
      </nav>
    </header>
  `;
}

async function renderLibrary() {
  let books = [];
  let error = "";
  try {
    books = (await api("/api/books")).books;
  } catch (err) {
    error = err.message;
  }

  app.innerHTML = `
    ${topbar("library")}
    <section class="hero">
      <h1>有人写，有人读。</h1>
      <p>作者在写作室写下章节，发布之后，读者就能在这里翻开。先从下面这本样书开始。</p>
    </section>
    ${error ? `<p class="empty flash">${escapeHtml(error)}</p>` : ""}
    ${
      books.length
        ? `<section class="grid">${books
            .map(
              (book) => `
            <a class="card" href="#/book/${book.id}">
              <div class="cover ${escapeHtml(book.cover || "ink")}">${escapeHtml(book.title)}</div>
              <div class="card-body">
                <div class="meta">${escapeHtml(book.author)} · ${book.chapterCount} 章</div>
                <p>${escapeHtml(book.tagline || "打开看看。")}</p>
              </div>
            </a>`
            )
            .join("")}</section>`
        : `<p class="empty">书库还是空的。作者可以到写作室发布第一本书。</p>`
    }
  `;
}

async function renderBook(id) {
  let book;
  try {
    book = (await api(`/api/books/${id}`)).book;
  } catch (err) {
    app.innerHTML = `${topbar("library")}<p class="empty flash">${escapeHtml(err.message)}</p>`;
    return;
  }

  const chapters = book.chapters || [];
  app.innerHTML = `
    ${topbar("library")}
    <section class="layout">
      <aside class="panel">
        <div class="cover ${escapeHtml(book.cover || "ink")}" style="height:180px;border-radius:14px;">${escapeHtml(book.title)}</div>
        <p class="muted" style="margin-top:16px;">${escapeHtml(book.author)}</p>
        <p>${escapeHtml(book.tagline || "")}</p>
      </aside>
      <div class="panel">
        <h2>目录</h2>
        <p class="muted">共 ${chapters.length} 章</p>
        ${
          chapters.length
            ? `<ol class="chapters">${chapters
                .map(
                  (chapter, index) => `
              <li>
                <a href="#/read/${book.id}/${chapter.id}">第 ${index + 1} 章 · ${escapeHtml(chapter.title)}</a>
              </li>`
                )
                .join("")}</ol>`
            : `<p class="muted">还没有章节。</p>`
        }
      </div>
    </section>
  `;
}

async function renderRead(bookId, chapterId) {
  let book;
  try {
    book = (await api(`/api/books/${bookId}`)).book;
  } catch (err) {
    app.innerHTML = `${topbar("library")}<p class="empty flash">${escapeHtml(err.message)}</p>`;
    return;
  }
  const chapters = book.chapters || [];
  const index = chapters.findIndex((chapter) => chapter.id === chapterId);
  const chapter = chapters[index];
  if (!chapter) {
    app.innerHTML = `${topbar("library")}<p class="empty flash">找不到这一章</p>`;
    return;
  }
  const prev = chapters[index - 1];
  const next = chapters[index + 1];

  app.innerHTML = `
    ${topbar("library")}
    <article class="reader">
      <div class="kicker">${escapeHtml(book.title)} · 第 ${index + 1} / ${chapters.length} 章</div>
      <h1>${escapeHtml(chapter.title)}</h1>
      <div class="prose">${paragraphs(chapter.body)}</div>
      <div class="pager">
        ${prev ? `<a class="btn" href="#/read/${book.id}/${prev.id}">上一章</a>` : `<a class="btn" href="#/book/${book.id}">回目录</a>`}
        ${next ? `<a class="btn btn-primary" href="#/read/${book.id}/${next.id}">下一章</a>` : `<a class="btn btn-primary" href="#/book/${book.id}">读完了</a>`}
      </div>
    </article>
  `;
}

function loginForm(message) {
  return `
    ${topbar("studio")}
    <section class="studio">
      <div class="panel" style="max-width:460px;">
        <h2>写作室</h2>
        <p class="muted">输入作者密码后，就可以新建书籍、写章节、选择发布给读者。</p>
        ${message ? `<p class="flash">${escapeHtml(message)}</p>` : ""}
        <form class="form" id="login-form">
          <label>密码
            <input type="password" name="password" autocomplete="current-password" required />
          </label>
          <button class="btn btn-primary" type="submit">进入</button>
        </form>
      </div>
    </section>
  `;
}

async function renderStudio() {
  if (!password()) {
    app.innerHTML = loginForm("");
    bindLogin();
    return;
  }

  let books = [];
  try {
    books = (await api("/api/books")).books;
  } catch (err) {
    sessionStorage.removeItem(PASS_KEY);
    app.innerHTML = loginForm(err.message);
    bindLogin();
    return;
  }

  app.innerHTML = `
    ${topbar("studio")}
    <section class="studio">
      <div class="layout" style="padding:0;">
        <aside class="panel">
          <h2>新书</h2>
          <form class="form" id="new-book">
            <label>书名 <input name="title" required /></label>
            <label>作者 <input name="author" value="Ra" /></label>
            <label>一句话简介 <input name="tagline" /></label>
            <label>封面
              <select name="cover">${covers.map(([id, label]) => `<option value="${id}">${label}</option>`).join("")}</select>
            </label>
            <button class="btn btn-primary" type="submit">创建草稿</button>
          </form>
        </aside>
        <div class="panel">
          <h2>我的书</h2>
          ${
            books.length
              ? `<ol class="chapters">${books
                  .map(
                    (book) => `
                <li>
                  <a href="#/studio/book/${book.id}">
                    ${escapeHtml(book.title)}
                    <span class="badge">${book.status === "published" ? "已发布" : "草稿"} · ${book.chapterCount} 章</span>
                  </a>
                </li>`
                  )
                  .join("")}</ol>`
              : `<p class="muted">还没有书。左边创建一个吧。</p>`
          }
        </div>
      </div>
    </section>
  `;

  document.getElementById("new-book").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = new FormData(event.target);
    try {
      const created = await api("/api/books", {
        method: "POST",
        body: JSON.stringify({
          title: form.get("title"),
          author: form.get("author"),
          tagline: form.get("tagline"),
          cover: form.get("cover"),
          status: "draft",
        }),
      });
      location.hash = `#/studio/book/${created.book.id}`;
    } catch (err) {
      alert(err.message);
    }
  });
}

function bindLogin() {
  document.getElementById("login-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const value = new FormData(event.target).get("password");
    try {
      await api("/api/auth", {
        method: "POST",
        body: JSON.stringify({ password: value }),
      });
      sessionStorage.setItem(PASS_KEY, String(value));
      render();
    } catch (err) {
      app.innerHTML = loginForm(err.message);
      bindLogin();
    }
  });
}

async function renderStudioBook(id) {
  if (!password()) {
    location.hash = "#/studio";
    return;
  }
  let book;
  try {
    book = (await api(`/api/books/${id}`)).book;
  } catch (err) {
    app.innerHTML = `${topbar("studio")}<p class="empty flash">${escapeHtml(err.message)}</p>`;
    return;
  }

  const chapters = book.chapters || [];
  app.innerHTML = `
    ${topbar("studio")}
    <section class="studio">
      <div class="layout" style="padding:0;">
        <aside class="panel">
          <p><a href="#/studio">← 全部书</a></p>
          <h2>书籍设定</h2>
          <form class="form" id="book-form">
            <label>书名 <input name="title" value="${escapeHtml(book.title)}" required /></label>
            <label>作者 <input name="author" value="${escapeHtml(book.author)}" /></label>
            <label>简介 <input name="tagline" value="${escapeHtml(book.tagline || "")}" /></label>
            <label>封面
              <select name="cover">${covers
                .map(([cid, label]) => `<option value="${cid}" ${cid === book.cover ? "selected" : ""}>${label}</option>`)
                .join("")}</select>
            </label>
            <label>状态
              <select name="status">
                <option value="draft" ${book.status !== "published" ? "selected" : ""}>草稿（仅作者可见）</option>
                <option value="published" ${book.status === "published" ? "selected" : ""}>发布（读者可见）</option>
              </select>
            </label>
            <div class="row">
              <button class="btn btn-primary" type="submit">保存</button>
              <button class="btn btn-danger" id="delete-book" type="button">删除这本书</button>
            </div>
          </form>
        </aside>
        <div class="panel">
          <div class="row" style="justify-content:space-between;">
            <h2>章节</h2>
            <button class="btn" id="add-chapter" type="button">新章节</button>
          </div>
          ${
            chapters.length
              ? `<ol class="chapters">${chapters
                  .map(
                    (chapter, index) => `
                <li>
                  <a href="#/studio/book/${book.id}/chapter/${chapter.id}">第 ${index + 1} 章 · ${escapeHtml(chapter.title)}</a>
                </li>`
                  )
                  .join("")}</ol>`
              : `<p class="muted">还没有章节。点右上角写第一章。</p>`
          }
        </div>
      </div>
    </section>
  `;

  document.getElementById("book-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = new FormData(event.target);
    try {
      await api(`/api/books/${book.id}`, {
        method: "PUT",
        body: JSON.stringify({
          title: form.get("title"),
          author: form.get("author"),
          tagline: form.get("tagline"),
          cover: form.get("cover"),
          status: form.get("status"),
        }),
      });
      render();
    } catch (err) {
      alert(err.message);
    }
  });

  document.getElementById("delete-book").addEventListener("click", async () => {
    if (!confirm("确定删除这本书和所有章节？")) return;
    try {
      await api(`/api/books/${book.id}`, { method: "DELETE" });
      location.hash = "#/studio";
    } catch (err) {
      alert(err.message);
    }
  });

  document.getElementById("add-chapter").addEventListener("click", async () => {
    try {
      const created = await api(`/api/books/${book.id}/chapters`, {
        method: "POST",
        body: JSON.stringify({ title: "新章节", body: "" }),
      });
      location.hash = `#/studio/book/${book.id}/chapter/${created.chapter.id}`;
    } catch (err) {
      alert(err.message);
    }
  });
}

async function renderStudioChapter(bookId, chapterId) {
  if (!password()) {
    location.hash = "#/studio";
    return;
  }
  let book;
  try {
    book = (await api(`/api/books/${bookId}`)).book;
  } catch (err) {
    app.innerHTML = `${topbar("studio")}<p class="empty flash">${escapeHtml(err.message)}</p>`;
    return;
  }
  const chapter = (book.chapters || []).find((item) => item.id === chapterId);
  if (!chapter) {
    app.innerHTML = `${topbar("studio")}<p class="empty flash">找不到这一章</p>`;
    return;
  }

  app.innerHTML = `
    ${topbar("studio")}
    <section class="studio">
      <div class="panel editor">
        <p><a href="#/studio/book/${book.id}">← ${escapeHtml(book.title)}</a></p>
        <h2>写这一章</h2>
        <form class="form" id="chapter-form">
          <label>标题 <input name="title" value="${escapeHtml(chapter.title)}" /></label>
          <label>正文
            <textarea name="body">${escapeHtml(chapter.body || "")}</textarea>
          </label>
          <div class="row">
            <button class="btn btn-primary" type="submit">保存章节</button>
            <button class="btn btn-danger" id="delete-chapter" type="button">删除章节</button>
            <a class="btn" href="#/read/${book.id}/${chapter.id}">预览阅读</a>
          </div>
        </form>
      </div>
    </section>
  `;

  document.getElementById("chapter-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = new FormData(event.target);
    try {
      await api(`/api/books/${book.id}/chapters/${chapter.id}`, {
        method: "PUT",
        body: JSON.stringify({
          title: form.get("title"),
          body: form.get("body"),
        }),
      });
      alert("已保存");
    } catch (err) {
      alert(err.message);
    }
  });

  document.getElementById("delete-chapter").addEventListener("click", async () => {
    if (!confirm("删除这一章？")) return;
    try {
      await api(`/api/books/${book.id}/chapters/${chapter.id}`, { method: "DELETE" });
      location.hash = `#/studio/book/${book.id}`;
    } catch (err) {
      alert(err.message);
    }
  });
}

async function render() {
  const { parts } = route();
  if (parts.length === 0) return renderLibrary();
  if (parts[0] === "book" && parts[1]) return renderBook(parts[1]);
  if (parts[0] === "read" && parts[1] && parts[2]) return renderRead(parts[1], parts[2]);
  if (parts[0] === "studio" && parts[1] === "book" && parts[2] && parts[3] === "chapter" && parts[4]) {
    return renderStudioChapter(parts[2], parts[4]);
  }
  if (parts[0] === "studio" && parts[1] === "book" && parts[2]) return renderStudioBook(parts[2]);
  if (parts[0] === "studio") return renderStudio();
  return renderLibrary();
}

window.addEventListener("hashchange", render);
render();
