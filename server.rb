#!/usr/bin/env ruby
# frozen_string_literal: true

require "webrick"
require "json"
require "securerandom"
require "fileutils"
require "time"
require "digest"

# macOS sandbox (and some hosts) block sendfile/copy_stream.
module Bookworms
  module ReadBody
    def send_body_io(socket)
      return super unless @body.respond_to?(:read)

      begin
        while (chunk = @body.read(16_384))
          socket.write(chunk)
        end
      ensure
        @body.close if @body.respond_to?(:close)
      end
    end
  end
end
WEBrick::HTTPResponse.prepend(Bookworms::ReadBody)

ROOT = File.expand_path(__dir__)
PUBLIC = File.join(ROOT, "public")
DATA_DIR = ENV["DATA_DIR"] && !ENV["DATA_DIR"].empty? ? ENV["DATA_DIR"] : File.join(ROOT, "data")
DATA_FILE = File.join(DATA_DIR, "books.json")
USERS_FILE = File.join(DATA_DIR, "users.json")
AUTHORS_FILE = File.join(DATA_DIR, "authors.json")
FRIENDS_FILE = File.join(DATA_DIR, "friends.json")
LIKES_FILE = File.join(DATA_DIR, "likes.json")
COMMENTS_FILE = File.join(DATA_DIR, "comments.json")
VERIFICATIONS_FILE = File.join(DATA_DIR, "verifications.json")
PORT = (ENV["PORT"] || "4567").to_i
BIND = ENV["BIND"] || "0.0.0.0"
MAX_COMMENT_LENGTH = 1000
EMAIL_PATTERN = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
PHONE_DIGITS_PATTERN = /\A\d{8,15}\z/
# Local/dev default: mock SMS/email (log code + return devCode). Set MOCK_VERIFY=0 when a real provider is wired.
MOCK_VERIFY = ENV.fetch("MOCK_VERIFY", "1") != "0"
VERIFY_TTL_SECONDS = (ENV["VERIFY_TTL_SECONDS"] || "600").to_i
VERIFY_DEV_CODE = ENV["VERIFY_DEV_CODE"].to_s.strip

FileUtils.mkdir_p(PUBLIC)
FileUtils.mkdir_p(DATA_DIR)

def seed_if_missing(filename)
  dest = File.join(DATA_DIR, filename)
  src = File.join(ROOT, "data", filename)
  return if File.file?(dest)
  if File.file?(src) && File.expand_path(src) != File.expand_path(dest)
    FileUtils.cp(src, dest)
  elsif %w[likes.json comments.json users.json friends.json verifications.json].include?(filename)
    File.write(dest, "[]\n", encoding: "UTF-8")
  end
end

%w[books.json authors.json users.json friends.json likes.json comments.json verifications.json].each { |name| seed_if_missing(name) }
File.write(VERIFICATIONS_FILE, "[]\n", encoding: "UTF-8") unless File.file?(VERIFICATIONS_FILE)

def load_list(path)
  return [] unless File.file?(path)
  JSON.parse(File.read(path, encoding: "UTF-8"))
rescue JSON::ParserError
  []
end

def save_list(path, items)
  tmp = "#{path}.tmp"
  File.write(tmp, JSON.pretty_generate(items), encoding: "UTF-8")
  File.rename(tmp, path)
end

def load_books
  load_list(DATA_FILE)
end

def save_books(books)
  save_list(DATA_FILE, books)
end

def load_users
  load_list(USERS_FILE)
end

def save_users(users)
  save_list(USERS_FILE, users)
end

def load_authors
  load_list(AUTHORS_FILE)
end

def save_authors(authors)
  save_list(AUTHORS_FILE, authors)
end

def load_friends
  load_list(FRIENDS_FILE)
end

def save_friends(friends)
  save_list(FRIENDS_FILE, friends)
end

def load_likes
  load_list(LIKES_FILE)
end

def save_likes(likes)
  save_list(LIKES_FILE, likes)
end

def load_comments
  load_list(COMMENTS_FILE)
end

def save_comments(comments)
  save_list(COMMENTS_FILE, comments)
end

def load_verifications
  load_list(VERIFICATIONS_FILE)
end

def save_verifications(items)
  save_list(VERIFICATIONS_FILE, items)
end

def hash_secret(secret, salt)
  Digest::SHA256.hexdigest("#{salt}:#{secret}")
end

def normalize_email(value)
  value.to_s.strip.downcase
end

def normalize_phone(value)
  value.to_s.strip.gsub(/[\s\-().]/, "")
end

def valid_email?(value)
  normalize_email(value).match?(EMAIL_PATTERN)
end

def valid_phone?(value)
  phone = normalize_phone(value)
  return false if phone.empty?
  phone = phone.sub(/\A\+/, "")
  phone.match?(PHONE_DIGITS_PATTERN)
end

def name_taken?(name)
  needle = name.to_s.downcase
  load_users.any? { |user| user["name"].to_s.downcase == needle } ||
    load_authors.any? { |author| author["name"].to_s.downcase == needle }
end

def email_taken?(email)
  needle = normalize_email(email)
  return false if needle.empty?
  load_users.any? { |user| normalize_email(user["email"]) == needle } ||
    load_authors.any? { |author| normalize_email(author["email"]) == needle }
end

def phone_taken?(phone)
  needle = normalize_phone(phone)
  return false if needle.empty?
  load_users.any? { |user| normalize_phone(user["phone"]) == needle } ||
    load_authors.any? { |author| normalize_phone(author["phone"]) == needle }
end

def find_account_by_login(accounts, login)
  needle = login.to_s.strip
  return nil if needle.empty?
  if needle.include?("@")
    email = normalize_email(needle)
    return accounts.find { |item| normalize_email(item["email"]) == email }
  end
  phone = normalize_phone(needle)
  return nil if phone.empty?
  accounts.find { |item| !item["phone"].to_s.empty? && normalize_phone(item["phone"]) == phone }
end

def public_reader(user)
  {
    "id" => user["id"],
    "name" => user["name"],
    "email" => user["email"].to_s,
    "phone" => user["phone"].to_s
  }
end

def public_author(author)
  {
    "id" => author["id"],
    "name" => author["name"],
    "email" => author["email"].to_s,
    "phone" => author["phone"].to_s
  }
end

def current_reader(req)
  token = req["X-Reader-Token"].to_s
  return nil if token.empty?
  load_users.find { |user| user["token"] == token }
end

def current_author(req)
  token = req["X-Author-Token"].to_s
  return nil if token.empty?
  load_authors.find { |author| !author["token"].to_s.empty? && author["token"] == token }
end

def author?(req)
  !current_author(req).nil?
end

def site_author
  load_authors.find { |author| author["id"] == "author-jc" } ||
    load_authors.find { |author| author["name"].to_s.casecmp("JC").zero? } ||
    load_authors.first
end

def site_author_name
  author = site_author
  return author["name"].to_s if author
  book = load_books.find { |item| item["status"] == "published" } || load_books.first
  book ? book["author"].to_s : "JC"
end

def default_author_id
  author = site_author
  author ? author["id"] : "author-jc"
end

def owns_book?(book, author)
  return false unless book && author
  return true if book["authorId"].to_s == author["id"].to_s
  book["authorId"].to_s.empty? && book["author"].to_s.casecmp(author["name"].to_s).zero?
end

def friend_for(reader, author_id = nil)
  return nil unless reader
  target = author_id.to_s.empty? ? default_author_id : author_id.to_s
  load_friends.find do |item|
    next false unless item["readerId"] == reader["id"]
    item_author = item["authorId"].to_s
    item_author.empty? ? target == default_author_id : item_author == target
  end
end

def friend_status_for(reader, author_id = nil)
  record = friend_for(reader, author_id)
  record ? record["status"] : "none"
end

def friend_of_author?(reader, author_id = nil)
  friend_status_for(reader, author_id) == "accepted"
end

def can_see_book?(book, req)
  author = current_author(req)
  return true if author && owns_book?(book, author)
  case book["status"]
  when "published" then true
  when "friends" then friend_of_author?(current_reader(req), book["authorId"])
  else false
  end
end

def require_book_owner!(req, res, book)
  author = current_author(req)
  unless author
    json!(res, { "error" => "請先以作者身分登入" }, 401)
    return nil
  end
  unless book && owns_book?(book, author)
    json!(res, { "error" => "找不到這本書" }, 404)
    return nil
  end
  author
end

def json!(res, payload, status = 200)
  res.status = status
  res["Content-Type"] = "application/json; charset=utf-8"
  res["Cache-Control"] = "no-store"
  res.body = JSON.generate(payload)
end

def parse_body(req)
  raw = req.body.to_s
  raw.empty? ? {} : JSON.parse(raw)
rescue JSON::ParserError
  nil
end

def find_book(id)
  load_books.find { |book| book["id"] == id }
end

def find_chapter(book, chapter_id)
  Array(book && book["chapters"]).find { |chapter| chapter["id"] == chapter_id }
end

def chapter_likes(book_id, chapter_id)
  load_likes.select { |item| item["bookId"] == book_id && item["chapterId"] == chapter_id }
end

def chapter_comments(book_id, chapter_id)
  load_comments
    .select { |item| item["bookId"] == book_id && item["chapterId"] == chapter_id }
    .sort_by { |item| item["createdAt"].to_s }
end

def public_comment(comment)
  {
    "id" => comment["id"],
    "readerId" => comment["readerId"],
    "readerName" => comment["readerName"],
    "body" => comment["body"],
    "createdAt" => comment["createdAt"]
  }
end

def engagement_payload(book_id, chapter_id, reader)
  likes = chapter_likes(book_id, chapter_id)
  {
    "likeCount" => likes.length,
    "liked" => reader ? likes.any? { |item| item["readerId"] == reader["id"] } : false,
    "comments" => chapter_comments(book_id, chapter_id).map { |item| public_comment(item) }
  }
end

def purge_chapter_engagement(book_id, chapter_id = nil)
  likes = load_likes.reject do |item|
    item["bookId"] == book_id && (chapter_id.nil? || item["chapterId"] == chapter_id)
  end
  comments = load_comments.reject do |item|
    item["bookId"] == book_id && (chapter_id.nil? || item["chapterId"] == chapter_id)
  end
  save_likes(likes)
  save_comments(comments)
end

def normalize_status(value)
  case value.to_s
  when "published" then "published"
  when "friends" then "friends"
  else "draft"
  end
end

def public_book(book)
  {
    "id" => book["id"],
    "title" => book["title"],
    "author" => book["author"],
    "authorId" => book["authorId"],
    "tagline" => book["tagline"],
    "cover" => book["cover"],
    "status" => book["status"],
    "updatedAt" => book["updatedAt"],
    "chapterCount" => Array(book["chapters"]).length
  }
end

def register_account_fields(body)
  name = body["name"].to_s.strip
  email = normalize_email(body["email"])
  phone_raw = body["phone"].to_s.strip
  phone = phone_raw.empty? ? "" : normalize_phone(phone_raw)
  secret = body["password"].to_s
  if name.length < 2 || name.length > 20
    return [nil, "請填寫 2 到 20 個字的名字"]
  end
  if email.empty?
    return [nil, "請填寫電子信箱"]
  end
  unless valid_email?(email)
    return [nil, "電子信箱格式不正確"]
  end
  if !phone.empty? && !valid_phone?(phone)
    return [nil, "電話格式不正確（選填；若填寫請用 8–15 位數字）"]
  end
  if secret.length < 4
    return [nil, "密碼至少 4 個字"]
  end
  if name_taken?(name)
    return [nil, "這個名字已經有人用了"]
  end
  if email_taken?(email)
    return [nil, "這個電子信箱已經有人用了"]
  end
  if !phone.empty? && phone_taken?(phone)
    return [nil, "這個電話已經有人用了"]
  end
  [{ "name" => name, "email" => email, "phone" => phone, "password" => secret }, nil]
end

def now
  Time.now.utc.iso8601
end

def parse_time(value)
  Time.parse(value.to_s).utc
rescue ArgumentError, TypeError
  nil
end

def prune_verifications!(items = nil)
  list = items || load_verifications
  stamp = Time.now.utc
  kept = list.reject do |item|
    expires = parse_time(item["expiresAt"])
    expires.nil? || expires <= stamp
  end
  save_verifications(kept) if kept.length != list.length
  kept
end

def issue_verification!(role, email, phone)
  code = VERIFY_DEV_CODE.empty? ? format("%06d", SecureRandom.random_number(1_000_000)) : VERIFY_DEV_CODE
  salt = SecureRandom.hex(8)
  stamp = Time.now.utc
  record = {
    "id" => SecureRandom.hex(8),
    "role" => role.to_s,
    "email" => email,
    "phone" => phone.to_s,
    "salt" => salt,
    "codeHash" => hash_secret(code, salt),
    "createdAt" => stamp.iso8601,
    "expiresAt" => (stamp + VERIFY_TTL_SECONDS).iso8601
  }
  items = prune_verifications!
  items.reject! { |item| item["role"] == role.to_s && item["email"] == email }
  items << record
  save_verifications(items)

  channels = ["email:#{email}"]
  channels << "phone:#{phone}" unless phone.to_s.empty?
  $stderr.puts "[verify] role=#{role} to=#{channels.join(',')} code=#{code} mock=#{MOCK_VERIFY}"

  payload = {
    "ok" => true,
    "expiresIn" => VERIFY_TTL_SECONDS,
    "sentTo" => {
      "email" => email,
      "phone" => phone.to_s.empty? ? nil : phone
    },
    "mock" => MOCK_VERIFY
  }
  payload["devCode"] = code if MOCK_VERIFY
  payload
end

def consume_verification!(role, email, phone, code)
  code = code.to_s.strip
  return "請填寫驗證碼" if code.empty?
  items = prune_verifications!
  index = items.index do |item|
    item["role"] == role.to_s &&
      item["email"] == email &&
      item["phone"].to_s == phone.to_s
  end
  return "請先發送驗證碼" if index.nil?
  record = items[index]
  expires = parse_time(record["expiresAt"])
  if expires.nil? || expires <= Time.now.utc
    items.delete_at(index)
    save_verifications(items)
    return "驗證碼已過期，請重新發送"
  end
  unless record["codeHash"] == hash_secret(code, record["salt"])
    return "驗證碼不正確"
  end
  items.delete_at(index)
  save_verifications(items)
  nil
end

server = WEBrick::HTTPServer.new(
  BindAddress: BIND,
  Port: PORT,
  DocumentRoot: PUBLIC,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
)

server.mount_proc "/healthz" do |_req, res|
  res.status = 200
  res["Content-Type"] = "text/plain; charset=utf-8"
  res.body = "ok"
end

server.mount_proc "/api" do |req, res|
  path = req.path_info.to_s.sub(%r{\A/}, "")
  parts = path.split("/").reject(&:empty?)
  method = req.request_method

  begin
    if method == "POST" && parts == ["verify", "send"]
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      role = body["role"].to_s
      unless %w[author reader].include?(role)
        json!(res, { "error" => "無效的驗證類型" }, 400)
        next
      end
      email = normalize_email(body["email"])
      phone_raw = body["phone"].to_s.strip
      phone = phone_raw.empty? ? "" : normalize_phone(phone_raw)
      if email.empty?
        json!(res, { "error" => "請填寫電子信箱" }, 400)
        next
      end
      unless valid_email?(email)
        json!(res, { "error" => "電子信箱格式不正確" }, 400)
        next
      end
      if !phone.empty? && !valid_phone?(phone)
        json!(res, { "error" => "電話格式不正確（選填；若填寫請用 8–15 位數字）" }, 400)
        next
      end
      if email_taken?(email)
        json!(res, { "error" => "這個電子信箱已經有人用了" }, 409)
        next
      end
      if !phone.empty? && phone_taken?(phone)
        json!(res, { "error" => "這個電話已經有人用了" }, 409)
        next
      end
      json!(res, issue_verification!(role, email, phone))
    elsif method == "POST" && parts == ["authors"]
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      fields, error = register_account_fields(body)
      if error
        json!(res, { "error" => error }, 400)
        next
      end
      verify_error = consume_verification!("author", fields["email"], fields["phone"], body["code"])
      if verify_error
        json!(res, { "error" => verify_error }, 400)
        next
      end
      salt = SecureRandom.hex(8)
      stamp = now
      author = {
        "id" => SecureRandom.hex(8),
        "name" => fields["name"],
        "email" => fields["email"],
        "phone" => fields["phone"],
        "salt" => salt,
        "passwordHash" => hash_secret(fields["password"], salt),
        "token" => SecureRandom.hex(24),
        "createdAt" => stamp
      }
      authors = load_authors
      authors << author
      save_authors(authors)
      json!(res, { "author" => public_author(author), "token" => author["token"] }, 201)
    elsif method == "POST" && parts == ["authors", "login"]
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      login = body["login"].to_s.strip
      login = body["email"].to_s.strip if login.empty?
      login = body["phone"].to_s.strip if login.empty?
      secret = body["password"].to_s
      if login.empty?
        json!(res, { "error" => "請填寫電子信箱或電話" }, 400)
        next
      end
      authors = load_authors
      author = find_account_by_login(authors, login)
      index = author ? authors.index { |item| item["id"] == author["id"] } : nil
      if author.nil? || index.nil? || author["passwordHash"] != hash_secret(secret, author["salt"])
        json!(res, { "error" => "電子信箱／電話或密碼不對" }, 401)
        next
      end
      author["token"] = SecureRandom.hex(24)
      authors[index] = author
      save_authors(authors)
      json!(res, { "author" => public_author(author), "token" => author["token"] })
    elsif method == "GET" && parts == ["authors", "me"]
      author = current_author(req)
      json!(res, { "author" => author ? public_author(author) : nil })
    elsif method == "GET" && parts == ["authors", "books"]
      author = current_author(req)
      unless author
        json!(res, { "error" => "請先以作者身分登入" }, 401)
        next
      end
      books = load_books.select { |book| owns_book?(book, author) }
      json!(res, { "books" => books.map { |book| public_book(book) } })
    elsif method == "POST" && parts == ["readers"]
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      fields, error = register_account_fields(body)
      if error
        json!(res, { "error" => error }, 400)
        next
      end
      verify_error = consume_verification!("reader", fields["email"], fields["phone"], body["code"])
      if verify_error
        json!(res, { "error" => verify_error }, 400)
        next
      end
      salt = SecureRandom.hex(8)
      stamp = now
      user = {
        "id" => SecureRandom.hex(8),
        "name" => fields["name"],
        "email" => fields["email"],
        "phone" => fields["phone"],
        "salt" => salt,
        "passwordHash" => hash_secret(fields["password"], salt),
        "token" => SecureRandom.hex(24),
        "createdAt" => stamp
      }
      users = load_users
      users << user
      save_users(users)
      json!(res, { "reader" => public_reader(user), "token" => user["token"], "friendStatus" => "none", "authorName" => site_author_name }, 201)
    elsif method == "POST" && parts == ["readers", "login"]
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      login = body["login"].to_s.strip
      login = body["email"].to_s.strip if login.empty?
      login = body["phone"].to_s.strip if login.empty?
      secret = body["password"].to_s
      if login.empty?
        json!(res, { "error" => "請填寫電子信箱或電話" }, 400)
        next
      end
      users = load_users
      user = find_account_by_login(users, login)
      index = user ? users.index { |item| item["id"] == user["id"] } : nil
      if user.nil? || index.nil? || user["passwordHash"] != hash_secret(secret, user["salt"])
        json!(res, { "error" => "電子信箱／電話或密碼不對" }, 401)
        next
      end
      user["token"] = SecureRandom.hex(24)
      users[index] = user
      save_users(users)
      json!(res, { "reader" => public_reader(user), "token" => user["token"], "friendStatus" => friend_status_for(user), "authorName" => site_author_name })
    elsif method == "GET" && parts == ["me"]
      reader = current_reader(req)
      json!(res, {
        "reader" => reader ? public_reader(reader) : nil,
        "friendStatus" => friend_status_for(reader),
        "authorName" => site_author_name
      })
    elsif method == "POST" && parts == ["friends"]
      reader = current_reader(req)
      unless reader
        json!(res, { "error" => "請先登入" }, 401)
        next
      end
      body = parse_body(req) || {}
      author_id = body["authorId"].to_s
      author_id = default_author_id if author_id.empty?
      unless load_authors.any? { |author| author["id"] == author_id }
        json!(res, { "error" => "找不到這位作者" }, 404)
        next
      end
      friends = load_friends
      record = friend_for(reader, author_id)
      stamp = now
      if record.nil?
        record = {
          "id" => SecureRandom.hex(8),
          "readerId" => reader["id"],
          "readerName" => reader["name"],
          "authorId" => author_id,
          "status" => "pending",
          "createdAt" => stamp,
          "updatedAt" => stamp
        }
        friends << record
      elsif record["status"] == "accepted"
        json!(res, { "error" => "你們已經是朋友了", "friend" => record })
        next
      elsif record["status"] == "pending"
        json!(res, { "error" => "已經送出申請，請等作者回覆", "friend" => record }, 409)
        next
      else
        record["status"] = "pending"
        record["readerName"] = reader["name"]
        record["authorId"] = author_id
        record["updatedAt"] = stamp
      end
      save_friends(friends)
      json!(res, { "friend" => record, "friendStatus" => record["status"] }, 201)
    elsif method == "GET" && parts == ["friends"]
      author = current_author(req)
      unless author
        json!(res, { "error" => "請先以作者身分登入" }, 401)
        next
      end
      friends = load_friends.select do |item|
        item_author = item["authorId"].to_s
        item_author.empty? ? author["id"] == default_author_id : item_author == author["id"]
      end
      friends = friends.sort_by { |item| item["updatedAt"].to_s }.reverse
      json!(res, { "friends" => friends })
    elsif method == "POST" && parts.length == 3 && parts[0] == "friends" && %w[accept reject].include?(parts[2])
      author = current_author(req)
      unless author
        json!(res, { "error" => "請先以作者身分登入" }, 401)
        next
      end
      friends = load_friends
      index = friends.index { |item| item["id"] == parts[1] }
      if index.nil?
        json!(res, { "error" => "找不到這則申請" }, 404)
        next
      end
      record = friends[index]
      item_author = record["authorId"].to_s
      allowed = item_author.empty? ? author["id"] == default_author_id : item_author == author["id"]
      unless allowed
        json!(res, { "error" => "找不到這則申請" }, 404)
        next
      end
      friends[index]["status"] = parts[2] == "accept" ? "accepted" : "rejected"
      friends[index]["authorId"] = author["id"] if friends[index]["authorId"].to_s.empty?
      friends[index]["updatedAt"] = now
      save_friends(friends)
      json!(res, { "friend" => friends[index] })
    elsif method == "GET" && parts == ["books"]
      books = load_books.select { |book| can_see_book?(book, req) }
      json!(res, { "books" => books.map { |book| public_book(book) } })
    elsif method == "GET" && parts.length == 2 && parts[0] == "books"
      book = find_book(parts[1])
      if book.nil? || !can_see_book?(book, req)
        json!(res, { "error" => "找不到這本書" }, 404)
      else
        json!(res, { "book" => book })
      end
    elsif method == "POST" && parts == ["books"]
      author = current_author(req)
      unless author
        json!(res, { "error" => "請先以作者身分登入" }, 401)
        next
      end
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      title = body["title"].to_s.strip
      if title.empty?
        json!(res, { "error" => "請填寫書名" }, 400)
        next
      end
      stamp = now
      display_name = body["author"].to_s.strip
      display_name = author["name"] if display_name.empty?
      book = {
        "id" => SecureRandom.hex(8),
        "title" => title,
        "author" => display_name,
        "authorId" => author["id"],
        "tagline" => body["tagline"].to_s.strip,
        "cover" => body["cover"].to_s.strip.empty? ? "ink" : body["cover"].to_s.strip,
        "status" => normalize_status(body["status"]),
        "createdAt" => stamp,
        "updatedAt" => stamp,
        "chapters" => []
      }
      books = load_books
      books.unshift(book)
      save_books(books)
      json!(res, { "book" => book }, 201)
    elsif method == "PUT" && parts.length == 2 && parts[0] == "books"
      books = load_books
      index = books.index { |item| item["id"] == parts[1] }
      book = index ? books[index] : nil
      unless require_book_owner!(req, res, book)
        next
      end
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      book["title"] = body["title"].to_s.strip unless body["title"].nil?
      book["author"] = body["author"].to_s.strip unless body["author"].nil?
      book["tagline"] = body["tagline"].to_s.strip unless body["tagline"].nil?
      book["cover"] = body["cover"].to_s.strip unless body["cover"].nil?
      if body.key?("status")
        book["status"] = normalize_status(body["status"])
      end
      if book["title"].to_s.empty?
        json!(res, { "error" => "請填寫書名" }, 400)
        next
      end
      book["authorId"] = current_author(req)["id"] if book["authorId"].to_s.empty?
      book["updatedAt"] = now
      books[index] = book
      save_books(books)
      json!(res, { "book" => book })
    elsif method == "DELETE" && parts.length == 2 && parts[0] == "books"
      books = load_books
      index = books.index { |item| item["id"] == parts[1] }
      book = index ? books[index] : nil
      unless require_book_owner!(req, res, book)
        next
      end
      books.delete_at(index)
      save_books(books)
      purge_chapter_engagement(parts[1])
      json!(res, { "ok" => true })
    elsif method == "POST" && parts.length == 3 && parts[0] == "books" && parts[2] == "chapters"
      books = load_books
      index = books.index { |item| item["id"] == parts[1] }
      book = index ? books[index] : nil
      unless require_book_owner!(req, res, book)
        next
      end
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      title = body["title"].to_s.strip
      title = "未命名章節" if title.empty?
      stamp = now
      chapter = {
        "id" => SecureRandom.hex(8),
        "title" => title,
        "body" => body["body"].to_s,
        "createdAt" => stamp,
        "updatedAt" => stamp
      }
      books[index]["chapters"] ||= []
      books[index]["chapters"] << chapter
      books[index]["updatedAt"] = stamp
      save_books(books)
      json!(res, { "chapter" => chapter, "book" => books[index] }, 201)
    elsif method == "PUT" && parts.length == 4 && parts[0] == "books" && parts[2] == "chapters"
      books = load_books
      index = books.index { |item| item["id"] == parts[1] }
      book = index ? books[index] : nil
      unless require_book_owner!(req, res, book)
        next
      end
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      chapters = Array(books[index]["chapters"])
      cindex = chapters.index { |item| item["id"] == parts[3] }
      if cindex.nil?
        json!(res, { "error" => "找不到這一章" }, 404)
        next
      end
      chapter = chapters[cindex]
      chapter["title"] = body["title"].to_s.strip unless body["title"].nil?
      chapter["title"] = "未命名章節" if chapter["title"].to_s.empty?
      chapter["body"] = body["body"].to_s unless body["body"].nil?
      chapter["updatedAt"] = now
      chapters[cindex] = chapter
      books[index]["chapters"] = chapters
      books[index]["updatedAt"] = chapter["updatedAt"]
      save_books(books)
      json!(res, { "chapter" => chapter, "book" => books[index] })
    elsif method == "DELETE" && parts.length == 4 && parts[0] == "books" && parts[2] == "chapters"
      books = load_books
      index = books.index { |item| item["id"] == parts[1] }
      book = index ? books[index] : nil
      unless require_book_owner!(req, res, book)
        next
      end
      chapters = Array(books[index]["chapters"])
      before = chapters.length
      chapters.reject! { |item| item["id"] == parts[3] }
      if chapters.length == before
        json!(res, { "error" => "找不到這一章" }, 404)
        next
      end
      books[index]["chapters"] = chapters
      books[index]["updatedAt"] = now
      save_books(books)
      purge_chapter_engagement(parts[1], parts[3])
      json!(res, { "ok" => true, "book" => books[index] })
    elsif method == "GET" && parts.length == 5 && parts[0] == "books" && parts[2] == "chapters" && parts[4] == "engagement"
      book = find_book(parts[1])
      if book.nil? || !can_see_book?(book, req) || find_chapter(book, parts[3]).nil?
        json!(res, { "error" => "找不到這一章" }, 404)
        next
      end
      json!(res, engagement_payload(parts[1], parts[3], current_reader(req)))
    elsif method == "POST" && parts.length == 5 && parts[0] == "books" && parts[2] == "chapters" && parts[4] == "like"
      reader = current_reader(req)
      unless reader
        json!(res, { "error" => "請先登入再按讚" }, 401)
        next
      end
      book = find_book(parts[1])
      if book.nil? || !can_see_book?(book, req) || find_chapter(book, parts[3]).nil?
        json!(res, { "error" => "找不到這一章" }, 404)
        next
      end
      likes = load_likes
      existing = likes.index { |item| item["bookId"] == parts[1] && item["chapterId"] == parts[3] && item["readerId"] == reader["id"] }
      if existing
        likes.delete_at(existing)
        save_likes(likes)
      else
        likes << {
          "id" => SecureRandom.hex(8),
          "bookId" => parts[1],
          "chapterId" => parts[3],
          "readerId" => reader["id"],
          "readerName" => reader["name"],
          "createdAt" => now
        }
        save_likes(likes)
      end
      json!(res, engagement_payload(parts[1], parts[3], reader))
    elsif method == "POST" && parts.length == 5 && parts[0] == "books" && parts[2] == "chapters" && parts[4] == "comments"
      reader = current_reader(req)
      unless reader
        json!(res, { "error" => "請先登入再留言" }, 401)
        next
      end
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      book = find_book(parts[1])
      if book.nil? || !can_see_book?(book, req) || find_chapter(book, parts[3]).nil?
        json!(res, { "error" => "找不到這一章" }, 404)
        next
      end
      text = body["body"].to_s.strip
      if text.empty?
        json!(res, { "error" => "請寫一點內容再送出" }, 400)
        next
      end
      if text.length > MAX_COMMENT_LENGTH
        json!(res, { "error" => "留言請在 #{MAX_COMMENT_LENGTH} 字以內" }, 400)
        next
      end
      stamp = now
      comment = {
        "id" => SecureRandom.hex(8),
        "bookId" => parts[1],
        "chapterId" => parts[3],
        "readerId" => reader["id"],
        "readerName" => reader["name"],
        "body" => text,
        "createdAt" => stamp
      }
      comments = load_comments
      comments << comment
      save_comments(comments)
      payload = engagement_payload(parts[1], parts[3], reader)
      payload["comment"] = public_comment(comment)
      json!(res, payload, 201)
    else
      json!(res, { "error" => "未知介面" }, 404)
    end
  rescue StandardError => e
    json!(res, { "error" => "伺服器出錯", "detail" => e.message }, 500)
  end
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

$stderr.puts "Ink Bookworms 已啟動：http://127.0.0.1:#{PORT}"
$stderr.puts "寫作室：作者用電子信箱或電話 + 密碼登入（種子 JC 信箱 jc@inkbookworms.local / jcwrites）"
$stderr.puts "註冊驗證：MOCK_VERIFY=#{MOCK_VERIFY ? 'on' : 'off'}（本地會在日誌印出驗證碼，且 API 回傳 devCode）"
server.start
