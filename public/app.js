const app = document.getElementById("app");
const AUTHOR_KEY = "bookworms.author";
const READER_KEY = "bookworms.reader";
let meCache = { reader: null, friendStatus: "none", authorName: "JC" };
let authorCache = null;

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
    return "<p class=\"muted\">這一章還是空白。</p>";
  }
  return chunks.map((chunk) => `<p>${escapeHtml(chunk).replace(/\n/g, "<br>")}</p>`).join("");
}

function authorSession() {
  try {
    return JSON.parse(sessionStorage.getItem(AUTHOR_KEY) || "null");
  } catch (err) {
    return null;
  }
}

function setAuthorSession(data) {
  if (!data) sessionStorage.removeItem(AUTHOR_KEY);
  else sessionStorage.setItem(AUTHOR_KEY, JSON.stringify(data));
}

function readerSession() {
  try {
    return JSON.parse(sessionStorage.getItem(READER_KEY) || "null");
  } catch (err) {
    return null;
  }
}

function setReaderSession(data) {
  if (!data) sessionStorage.removeItem(READER_KEY);
  else sessionStorage.setItem(READER_KEY, JSON.stringify(data));
}

function headers(extra) {
  const result = { "Content-Type": "application/json", ...(extra || {}) };
  const authorToken = authorSession()?.token;
  if (authorToken) result["X-Author-Token"] = authorToken;
  const token = readerSession()?.token;
  if (token) result["X-Reader-Token"] = token;
  return result;
}

function basicEmailOk(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(value || "").trim());
}

async function ensureMe() {
  try {
    meCache = await api("/api/me");
    if (meCache.reader && readerSession()?.token) {
      setReaderSession({ token: readerSession().token, name: meCache.reader.name });
    }
  } catch (err) {
    meCache = { reader: null, friendStatus: "none", authorName: "JC" };
  }
  return meCache;
}

async function ensureAuthor() {
  if (!authorSession()?.token) {
    authorCache = null;
    return null;
  }
  try {
    const data = await api("/api/authors/me");
    authorCache = data.author || null;
    if (!authorCache) setAuthorSession(null);
    else setAuthorSession({ token: authorSession().token, name: authorCache.name });
  } catch (err) {
    authorCache = null;
    setAuthorSession(null);
  }
  return authorCache;
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: headers(options.headers),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.error || "請求失敗");
  }
  return data;
}

function statusLabel(status) {
  if (status === "published") return "已發布";
  if (status === "friends") return "朋友可見";
  return "草稿";
}

function friendLine() {
  const author = meCache.authorName || "JC";
  if (!meCache.reader) {
    return `<p class="friend-line">登入後可以向作者 ${escapeHtml(author)} 申請成為朋友。</p>`;
  }
  if (meCache.friendStatus === "accepted") {
    return `<p class="friend-line">你已是 ${escapeHtml(author)} 的朋友，朋友可見的書也會出現在這裡。</p>`;
  }
  if (meCache.friendStatus === "pending") {
    return `<p class="friend-line">已向 ${escapeHtml(author)} 送出申請，等待作者同意。</p>`;
  }
  return `
    <div class="friend-line row">
      <p>向作者 ${escapeHtml(author)} 申請成為朋友，同意後就能看到朋友可見的書。</p>
      <button class="btn" id="ask-friend" type="button">加為朋友</button>
    </div>
  `;
}

function bindFriendButton() {
  const button = document.getElementById("ask-friend");
  if (!button) return;
  button.addEventListener("click", async () => {
    try {
      await api("/api/friends", { method: "POST", body: JSON.stringify({}) });
      await ensureMe();
      render();
    } catch (err) {
      alert(err.message);
    }
  });
}

function topbar(active) {
  return `
    <header class="topbar">
      <a class="brand" href="#/">
        <strong>Ink Bookworms</strong>
        <span>寫給願意停下來的人</span>
      </a>
      <nav class="nav">
        <a class="${active === "library" ? "active" : ""}" href="#/">書庫</a>
        <a class="${active === "studio" ? "active" : ""}" href="#/studio">寫作室</a>
        <a class="${active === "account" ? "active" : ""}" href="#/account">${
          meCache.reader ? escapeHtml(meCache.reader.name) : "登入"
        }</a>
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
      <h1>有人寫，有人讀。</h1>
      <p>給 9–18 歲年輕作者的寫作與閱讀網站。作者在寫作室寫下章節，發布後讀者就能在這裡翻開，並在正文下方按讚、留言討論。先從下面<span class="nowrap">這本樣書開始。</span></p>
      ${friendLine()}
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
                <p>${escapeHtml(book.tagline || "打開看看。")}</p>
              </div>
            </a>`
            )
            .join("")}</section>`
        : `<p class="empty">${
            meCache.friendStatus === "accepted"
              ? "目前還沒有你可以看的書。"
              : "書庫還是空的。作者可以到寫作室發布第一本書。"
          }</p>`
    }
  `;
  bindFriendButton();
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
        <p class="muted" style="margin-top:16px;">作者 ${escapeHtml(book.author)}</p>
        <p>${escapeHtml(book.tagline || "")}</p>
        ${friendLine()}
      </aside>
      <div class="panel">
        <h2>目錄</h2>
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
            : `<p class="muted">還沒有章節。</p>`
        }
      </div>
    </section>
  `;
  bindFriendButton();
}

function formatCommentTime(value) {
  const stamp = Date.parse(value || "");
  if (Number.isNaN(stamp)) return "";
  try {
    return new Intl.DateTimeFormat("zh-Hant", {
      month: "numeric",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    }).format(new Date(stamp));
  } catch (err) {
    return "";
  }
}

function renderCommentsList(comments) {
  if (!comments.length) {
    return `<p class="muted discussion-empty">還沒有留言。讀完有想法，就留一句給作者吧。</p>`;
  }
  return `<ol class="comment-list">${comments
    .map(
      (comment) => `
    <li class="comment">
      <div class="comment-meta">
        <strong>${escapeHtml(comment.readerName)}</strong>
        <span>${escapeHtml(formatCommentTime(comment.createdAt))}</span>
      </div>
      <p>${escapeHtml(comment.body).replace(/\n/g, "<br>")}</p>
    </li>`
    )
    .join("")}</ol>`;
}

function discussionMarkup(engagement) {
  const liked = engagement.liked;
  const likeCount = engagement.likeCount || 0;
  const comments = engagement.comments || [];
  const loggedIn = Boolean(meCache.reader);

  return `
    <section class="discussion" aria-label="章節討論">
      <div class="discussion-actions row">
        <button class="btn ${liked ? "btn-primary" : ""}" id="toggle-like" type="button" ${
          loggedIn ? "" : "disabled"
        }>
          ${liked ? "已按讚" : "按讚"} · ${likeCount}
        </button>
        ${
          loggedIn
            ? `<p class="muted discussion-hint">留言會出現在正文下方，不會改動作者的文字。</p>`
            : `<p class="muted discussion-hint"><a href="#/account">登入</a> 後可以按讚與留言。</p>`
        }
      </div>
      <div class="discussion-comments">
        <h2>留言 ${comments.length ? `· ${comments.length}` : ""}</h2>
        <div id="comment-list">${renderCommentsList(comments)}</div>
        ${
          loggedIn
            ? `
          <form class="form comment-form" id="comment-form">
            <label>寫下你的想法
              <textarea name="body" maxlength="1000" rows="4" required placeholder="這一章讓你想到什麼？"></textarea>
            </label>
            <button class="btn btn-primary" type="submit">送出留言</button>
          </form>`
            : ""
        }
      </div>
    </section>
  `;
}

function bindDiscussion(bookId, chapterId) {
  const likeButton = document.getElementById("toggle-like");
  if (likeButton && !likeButton.disabled) {
    likeButton.addEventListener("click", async () => {
      likeButton.disabled = true;
      try {
        const data = await api(`/api/books/${bookId}/chapters/${chapterId}/like`, {
          method: "POST",
          body: JSON.stringify({}),
        });
        const section = document.querySelector(".discussion");
        if (section) {
          section.outerHTML = discussionMarkup(data);
          bindDiscussion(bookId, chapterId);
        }
      } catch (err) {
        alert(err.message);
        likeButton.disabled = false;
      }
    });
  }

  const form = document.getElementById("comment-form");
  if (!form) return;
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const body = new FormData(event.target).get("body");
    const submit = form.querySelector('button[type="submit"]');
    if (submit) submit.disabled = true;
    try {
      const data = await api(`/api/books/${bookId}/chapters/${chapterId}/comments`, {
        method: "POST",
        body: JSON.stringify({ body }),
      });
      const section = document.querySelector(".discussion");
      if (section) {
        section.outerHTML = discussionMarkup(data);
        bindDiscussion(bookId, chapterId);
      }
    } catch (err) {
      alert(err.message);
      if (submit) submit.disabled = false;
    }
  });
}

async function renderRead(bookId, chapterId) {
  let book;
  let engagement = { likeCount: 0, liked: false, comments: [] };
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
    app.innerHTML = `${topbar("library")}<p class="empty flash">找不到這一章</p>`;
    return;
  }
  try {
    engagement = await api(`/api/books/${bookId}/chapters/${chapterId}/engagement`);
  } catch (err) {
    engagement = { likeCount: 0, liked: false, comments: [] };
  }
  const prev = chapters[index - 1];
  const next = chapters[index + 1];

  app.innerHTML = `
    ${topbar("library")}
    <article class="reader">
      <div class="kicker">${escapeHtml(book.title)} · 第 ${index + 1} / ${chapters.length} 章</div>
      <h1>${escapeHtml(chapter.title)}</h1>
      <div class="prose">${paragraphs(chapter.body)}</div>
      ${discussionMarkup(engagement)}
      <div class="pager">
        ${prev ? `<a class="btn" href="#/read/${book.id}/${prev.id}">上一章</a>` : `<a class="btn" href="#/book/${book.id}">回目錄</a>`}
        ${next ? `<a class="btn btn-primary" href="#/read/${book.id}/${next.id}">下一章</a>` : `<a class="btn btn-primary" href="#/book/${book.id}">讀完了</a>`}
      </div>
    </article>
  `;
  bindDiscussion(book.id, chapter.id);
}

function studioGate(message, hint) {
  return `
    ${topbar("studio")}
    <section class="studio">
      <div class="panel" style="max-width:460px;">
        <h2>寫作室</h2>
        <p class="muted">每位作者用自己的帳號登入。註冊需名字、電子信箱（必填）、電話（選填）與密碼，並完成驗證碼——適合 9–18 歲年輕作者在網站上寫作與發布。</p>
        ${message ? `<p class="flash">${escapeHtml(message)}</p>` : ""}
        ${hint ? `<p class="muted">${escapeHtml(hint)}</p>` : ""}
        <h3>登入</h3>
        <form class="form" id="author-login">
          <label>電子信箱或電話
            <input name="login" required autocomplete="username" placeholder="邮箱或电话" />
          </label>
          <label>密碼 <input type="password" name="password" required autocomplete="current-password" /></label>
          <button class="btn btn-primary" type="submit">進入寫作室</button>
        </form>
        <h3>還沒有作者帳號</h3>
        <form class="form" id="author-register">
          <label>名字（顯示用） <input name="name" required minlength="2" maxlength="20" autocomplete="nickname" /></label>
          <label>電子信箱 <input type="email" name="email" required autocomplete="email" placeholder="you@example.com" /></label>
          <label>電話（選填） <input name="phone" inputmode="tel" autocomplete="tel" placeholder="可留空" /></label>
          <label>密碼 <input type="password" name="password" required minlength="4" autocomplete="new-password" /></label>
          <div class="row" style="align-items:flex-end;">
            <label style="flex:1;">驗證碼
              <input name="code" required inputmode="numeric" autocomplete="one-time-code" placeholder="6 位驗證碼" />
            </label>
            <button class="btn" id="author-send-code" type="button">发送验证码</button>
          </div>
          <button class="btn btn-primary" type="submit">驗證並註冊</button>
        </form>
      </div>
    </section>
  `;
}

function registerPayloadFromForm(form) {
  return {
    name: String(form.get("name") || "").trim(),
    email: String(form.get("email") || "").trim(),
    phone: String(form.get("phone") || "").trim(),
    password: String(form.get("password") || ""),
    code: String(form.get("code") || "").trim(),
  };
}

function validateRegisterClient(fields) {
  if (!fields.email) return "請填寫電子信箱";
  if (!basicEmailOk(fields.email)) return "電子信箱格式不正確";
  if (fields.phone && !/^\+?[\d\s\-().]{8,20}$/.test(fields.phone)) {
    return "電話格式不正確（選填；若填寫請檢查位數）";
  }
  if (!fields.password || fields.password.length < 4) return "密碼至少 4 個字";
  return "";
}

function bindStudioGate() {
  const login = document.getElementById("author-login");
  if (login) {
    login.addEventListener("submit", async (event) => {
      event.preventDefault();
      const form = new FormData(event.target);
      try {
        const data = await api("/api/authors/login", {
          method: "POST",
          body: JSON.stringify({ login: form.get("login"), password: form.get("password") }),
        });
        setAuthorSession({ token: data.token, name: data.author.name });
        authorCache = data.author;
        render();
      } catch (err) {
        app.innerHTML = studioGate(err.message);
        bindStudioGate();
      }
    });
  }

  const sendCode = document.getElementById("author-send-code");
  if (sendCode) {
    sendCode.addEventListener("click", async () => {
      const formEl = document.getElementById("author-register");
      const form = new FormData(formEl);
      const fields = registerPayloadFromForm(form);
      const clientError = validateRegisterClient({ ...fields, password: fields.password || "****" });
      if (clientError && clientError !== "密碼至少 4 個字") {
        app.innerHTML = studioGate(clientError);
        bindStudioGate();
        return;
      }
      if (!fields.email || !basicEmailOk(fields.email)) {
        app.innerHTML = studioGate(!fields.email ? "請填寫電子信箱" : "電子信箱格式不正確");
        bindStudioGate();
        return;
      }
      sendCode.disabled = true;
      try {
        const data = await api("/api/verify/send", {
          method: "POST",
          body: JSON.stringify({
            role: "author",
            email: fields.email,
            phone: fields.phone,
          }),
        });
        const hint = data.devCode
          ? `本地測試：驗證碼是 ${data.devCode}（也會印在伺服器日誌）。`
          : "驗證碼已發送，請查收後填入。";
        app.innerHTML = studioGate("驗證碼已送出", hint);
        bindStudioGate();
        const again = document.getElementById("author-register");
        if (again) {
          again.name.value = fields.name;
          again.email.value = fields.email;
          again.phone.value = fields.phone;
          again.password.value = fields.password;
        }
      } catch (err) {
        app.innerHTML = studioGate(err.message);
        bindStudioGate();
      }
    });
  }

  const register = document.getElementById("author-register");
  if (!register) return;
  register.addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = new FormData(event.target);
    const fields = registerPayloadFromForm(form);
    const clientError = validateRegisterClient(fields);
    if (clientError) {
      app.innerHTML = studioGate(clientError);
      bindStudioGate();
      return;
    }
    if (!fields.code) {
      app.innerHTML = studioGate("請填寫驗證碼（先點「发送验证码」）");
      bindStudioGate();
      return;
    }
    try {
      const data = await api("/api/authors", {
        method: "POST",
        body: JSON.stringify(fields),
      });
      setAuthorSession({ token: data.token, name: data.author.name });
      authorCache = data.author;
      render();
    } catch (err) {
      app.innerHTML = studioGate(err.message);
      bindStudioGate();
    }
  });
}

async function renderStudio() {
  await ensureAuthor();
  if (!authorCache) {
    app.innerHTML = studioGate("");
    bindStudioGate();
    return;
  }

  let books = [];
  let friends = [];
  try {
    books = (await api("/api/authors/books")).books;
    friends = (await api("/api/friends")).friends;
  } catch (err) {
    setAuthorSession(null);
    authorCache = null;
    app.innerHTML = studioGate(err.message);
    bindStudioGate();
    return;
  }

  const pending = friends.filter((item) => item.status === "pending");
  const accepted = friends.filter((item) => item.status === "accepted");
  const authorName = authorCache.name || "作者";

  app.innerHTML = `
    ${topbar("studio")}
    <section class="studio">
      <div class="row" style="justify-content:space-between;margin:0 0 16px;padding:0 2px;">
        <p class="muted" style="margin:0;">你好，${escapeHtml(authorName)}。這裡只顯示你自己的書。</p>
        <button class="btn" id="logout-author" type="button">登出寫作室</button>
      </div>
      <div class="layout" style="padding:0;">
        <aside class="panel">
          <h2>新書</h2>
          <form class="form" id="new-book">
            <label>書名 <input name="title" required /></label>
            <label>作者 <input name="author" value="${escapeHtml(authorName)}" /></label>
            <label>一句話簡介 <input name="tagline" /></label>
            <label>封面
              <select name="cover">${covers.map(([id, label]) => `<option value="${id}">${label}</option>`).join("")}</select>
            </label>
            <button class="btn btn-primary" type="submit">建立草稿</button>
          </form>
        </aside>
        <div class="panel">
          <h2>我的書</h2>
          ${
            books.length
              ? `<ol class="chapters">${books
                  .map(
                    (book) => `
                <li>
                  <a href="#/studio/book/${book.id}">
                    ${escapeHtml(book.title)}
                    <span class="badge">${statusLabel(book.status)} · ${book.chapterCount} 章</span>
                  </a>
                </li>`
                  )
                  .join("")}</ol>`
              : `<p class="muted">還沒有書。左邊建立一本吧。</p>`
          }
        </div>
      </div>
      <div class="panel" style="margin-top:22px;">
        <h2>朋友申請</h2>
        <p class="muted">讀者登入後可以申請加你為朋友。你同意後，他們就能看到「朋友可見」的書。</p>
        ${
          pending.length
            ? `<ol class="chapters">${pending
                .map(
                  (item) => `
              <li class="row" style="justify-content:space-between;align-items:center;">
                <span>${escapeHtml(item.readerName)}</span>
                <span class="row">
                  <button class="btn btn-primary" data-accept="${item.id}" type="button">同意</button>
                  <button class="btn" data-reject="${item.id}" type="button">拒絕</button>
                </span>
              </li>`
                )
                .join("")}</ol>`
            : `<p class="muted">現在沒有待處理的申請。</p>`
        }
        ${
          accepted.length
            ? `<p class="muted" style="margin-top:18px;">已是朋友：${accepted
                .map((item) => escapeHtml(item.readerName))
                .join("、")}</p>`
            : ""
        }
      </div>
    </section>
  `;

  const logout = document.getElementById("logout-author");
  if (logout) {
    logout.addEventListener("click", () => {
      setAuthorSession(null);
      authorCache = null;
      render();
    });
  }

  document.querySelectorAll("[data-accept]").forEach((button) => {
    button.addEventListener("click", async () => {
      try {
        await api(`/api/friends/${button.getAttribute("data-accept")}/accept`, {
          method: "POST",
          body: JSON.stringify({}),
        });
        render();
      } catch (err) {
        alert(err.message);
      }
    });
  });
  document.querySelectorAll("[data-reject]").forEach((button) => {
    button.addEventListener("click", async () => {
      try {
        await api(`/api/friends/${button.getAttribute("data-reject")}/reject`, {
          method: "POST",
          body: JSON.stringify({}),
        });
        render();
      } catch (err) {
        alert(err.message);
      }
    });
  });

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

async function renderStudioBook(id) {
  await ensureAuthor();
  if (!authorCache) {
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
          <p><a href="#/studio">← 全部書</a></p>
          <h2>書籍設定</h2>
          <form class="form" id="book-form">
            <label>書名 <input name="title" value="${escapeHtml(book.title)}" required /></label>
            <label>作者 <input name="author" value="${escapeHtml(book.author)}" /></label>
            <label>簡介 <input name="tagline" value="${escapeHtml(book.tagline || "")}" /></label>
            <label>封面
              <select name="cover">${covers
                .map(([cid, label]) => `<option value="${cid}" ${cid === book.cover ? "selected" : ""}>${label}</option>`)
                .join("")}</select>
            </label>
            <label>狀態
              <select name="status">
                <option value="draft" ${book.status === "draft" || !book.status ? "selected" : ""}>草稿（僅作者可見）</option>
                <option value="friends" ${book.status === "friends" ? "selected" : ""}>發布（朋友可見）</option>
                <option value="published" ${book.status === "published" ? "selected" : ""}>發布（讀者可見）</option>
              </select>
            </label>
            <p class="muted">朋友可見只會出現在你已同意的朋友書庫裡，不會公開給所有讀者。</p>
            <div class="row">
              <button class="btn btn-primary" type="submit">儲存</button>
              <button class="btn btn-danger" id="delete-book" type="button">刪除這本書</button>
            </div>
          </form>
        </aside>
        <div class="panel">
          <div class="row" style="justify-content:space-between;">
            <h2>章節</h2>
            <button class="btn" id="add-chapter" type="button">新章節</button>
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
              : `<p class="muted">還沒有章節。點右上角寫第一章。</p>`
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
    if (!confirm("確定刪除這本書和所有章節？")) return;
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
        body: JSON.stringify({ title: "新章節", body: "" }),
      });
      location.hash = `#/studio/book/${book.id}/chapter/${created.chapter.id}`;
    } catch (err) {
      alert(err.message);
    }
  });
}

async function renderStudioChapter(bookId, chapterId) {
  await ensureAuthor();
  if (!authorCache) {
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
    app.innerHTML = `${topbar("studio")}<p class="empty flash">找不到這一章</p>`;
    return;
  }

  app.innerHTML = `
    ${topbar("studio")}
    <section class="studio">
      <div class="panel editor">
        <p><a href="#/studio/book/${book.id}">← ${escapeHtml(book.title)}</a></p>
        <h2>寫這一章</h2>
        <form class="form" id="chapter-form">
          <label>標題 <input name="title" value="${escapeHtml(chapter.title)}" /></label>
          <label>正文
            <textarea name="body">${escapeHtml(chapter.body || "")}</textarea>
          </label>
          <div class="row">
            <button class="btn btn-primary" type="submit">儲存章節</button>
            <button class="btn btn-danger" id="delete-chapter" type="button">刪除章節</button>
            <a class="btn" href="#/read/${book.id}/${chapter.id}">預覽閱讀</a>
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
      alert("已儲存");
    } catch (err) {
      alert(err.message);
    }
  });

  document.getElementById("delete-chapter").addEventListener("click", async () => {
    if (!confirm("刪除這一章？")) return;
    try {
      await api(`/api/books/${book.id}/chapters/${chapter.id}`, { method: "DELETE" });
      location.hash = `#/studio/book/${book.id}`;
    } catch (err) {
      alert(err.message);
    }
  });
}

async function renderAccount() {
  const author = meCache.authorName || "JC";
  app.innerHTML = `
    ${topbar("account")}
    <section class="studio">
      <div class="panel" style="max-width:460px;">
        <h2>${meCache.reader ? escapeHtml(meCache.reader.name) : "讀者登入"}</h2>
        ${
          meCache.reader
            ? `
          <p class="muted">登入後可以在章節下方按讚、留言，也可以向作者 ${escapeHtml(author)} 申請成為朋友。</p>
          ${friendLine()}
          <div class="row" style="margin-top:18px;">
            <button class="btn" id="logout-reader" type="button">登出</button>
          </div>
        `
            : `
          <p class="muted">登入後就能在章節下方按讚與留言，也可以向作者申請加為朋友。註冊需電子信箱（必填）、電話（選填）與驗證碼。作者同意後，你的書庫會多出朋友可見的書。</p>
          <p id="account-flash" class="flash" hidden></p>
          <p id="account-hint" class="muted" hidden></p>
          <h3>登入</h3>
          <form class="form" id="reader-login">
            <label>電子信箱或電話
              <input name="login" required autocomplete="username" placeholder="邮箱或电话" />
            </label>
            <label>密碼 <input type="password" name="password" required autocomplete="current-password" /></label>
            <button class="btn btn-primary" type="submit">登入</button>
          </form>
          <h3>還沒有帳號</h3>
          <form class="form" id="reader-register">
            <label>名字（顯示用） <input name="name" required minlength="2" maxlength="20" autocomplete="nickname" /></label>
            <label>電子信箱 <input type="email" name="email" required autocomplete="email" placeholder="you@example.com" /></label>
            <label>電話（選填） <input name="phone" inputmode="tel" autocomplete="tel" placeholder="可留空" /></label>
            <label>密碼 <input type="password" name="password" required minlength="4" autocomplete="new-password" /></label>
            <div class="row" style="align-items:flex-end;">
              <label style="flex:1;">驗證碼
                <input name="code" required inputmode="numeric" autocomplete="one-time-code" placeholder="6 位驗證碼" />
              </label>
              <button class="btn" id="reader-send-code" type="button">发送验证码</button>
            </div>
            <button class="btn" type="submit">驗證並註冊</button>
          </form>
        `
        }
      </div>
    </section>
  `;
  bindFriendButton();
  const logout = document.getElementById("logout-reader");
  if (logout) {
    logout.addEventListener("click", () => {
      setReaderSession(null);
      meCache = { reader: null, friendStatus: "none", authorName: author };
      render();
    });
  }
  const showAccountMessage = (message, hint) => {
    const flash = document.getElementById("account-flash");
    const hintEl = document.getElementById("account-hint");
    if (flash) {
      flash.hidden = !message;
      flash.textContent = message || "";
    }
    if (hintEl) {
      hintEl.hidden = !hint;
      hintEl.textContent = hint || "";
    }
  };

  const login = document.getElementById("reader-login");
  if (login) {
    login.addEventListener("submit", async (event) => {
      event.preventDefault();
      const form = new FormData(event.target);
      try {
        const data = await api("/api/readers/login", {
          method: "POST",
          body: JSON.stringify({ login: form.get("login"), password: form.get("password") }),
        });
        setReaderSession({ token: data.token, name: data.reader.name });
        await ensureMe();
        location.hash = "#/";
      } catch (err) {
        showAccountMessage(err.message);
      }
    });
  }

  const sendCode = document.getElementById("reader-send-code");
  if (sendCode) {
    sendCode.addEventListener("click", async () => {
      const formEl = document.getElementById("reader-register");
      const fields = registerPayloadFromForm(new FormData(formEl));
      if (!fields.email) {
        showAccountMessage("請填寫電子信箱");
        return;
      }
      if (!basicEmailOk(fields.email)) {
        showAccountMessage("電子信箱格式不正確");
        return;
      }
      if (fields.phone && !/^\+?[\d\s\-().]{8,20}$/.test(fields.phone)) {
        showAccountMessage("電話格式不正確（選填；若填寫請檢查位數）");
        return;
      }
      sendCode.disabled = true;
      try {
        const data = await api("/api/verify/send", {
          method: "POST",
          body: JSON.stringify({
            role: "reader",
            email: fields.email,
            phone: fields.phone,
          }),
        });
        const hint = data.devCode
          ? `本地測試：驗證碼是 ${data.devCode}（也會印在伺服器日誌）。`
          : "驗證碼已發送，請查收後填入。";
        showAccountMessage("驗證碼已送出", hint);
      } catch (err) {
        showAccountMessage(err.message);
      } finally {
        sendCode.disabled = false;
      }
    });
  }

  const register = document.getElementById("reader-register");
  if (register) {
    register.addEventListener("submit", async (event) => {
      event.preventDefault();
      const fields = registerPayloadFromForm(new FormData(event.target));
      const clientError = validateRegisterClient(fields);
      if (clientError) {
        showAccountMessage(clientError);
        return;
      }
      if (!fields.code) {
        showAccountMessage("請填寫驗證碼（先點「发送验证码」）");
        return;
      }
      try {
        const data = await api("/api/readers", {
          method: "POST",
          body: JSON.stringify(fields),
        });
        setReaderSession({ token: data.token, name: data.reader.name });
        await ensureMe();
        location.hash = "#/";
      } catch (err) {
        showAccountMessage(err.message);
      }
    });
  }
}

async function render() {
  await ensureMe();
  const { parts } = route();
  if (parts.length === 0) return renderLibrary();
  if (parts[0] === "account") return renderAccount();
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
