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
FRIENDS_FILE = File.join(DATA_DIR, "friends.json")
PASSWORD = ENV["BOOKWORMS_PASSWORD"] || "bookworms"
PORT = (ENV["PORT"] || "4567").to_i
BIND = ENV["BIND"] || "0.0.0.0"

FileUtils.mkdir_p(PUBLIC)
FileUtils.mkdir_p(DATA_DIR)
SEED_FILE = File.join(ROOT, "data", "books.json")
if !File.file?(DATA_FILE) && File.file?(SEED_FILE) && File.expand_path(SEED_FILE) != File.expand_path(DATA_FILE)
  FileUtils.cp(SEED_FILE, DATA_FILE)
end
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

def load_friends
  load_list(FRIENDS_FILE)
end

def save_friends(friends)
  save_list(FRIENDS_FILE, friends)
end

def hash_secret(secret, salt)
  Digest::SHA256.hexdigest("#{salt}:#{secret}")
end

def public_reader(user)
  { "id" => user["id"], "name" => user["name"] }
end

def current_reader(req)
  token = req["X-Reader-Token"].to_s
  return nil if token.empty?
  load_users.find { |user| user["token"] == token }
end

def site_author_name
  book = load_books.find { |item| item["status"] == "published" } || load_books.first
  book ? book["author"].to_s : "JC"
end

def friend_for(reader)
  return nil unless reader
  load_friends.find { |item| item["readerId"] == reader["id"] }
end

def friend_status_for(reader)
  record = friend_for(reader)
  record ? record["status"] : "none"
end

def friend_of_author?(reader)
  friend_status_for(reader) == "accepted"
end

def can_see_book?(book, req)
  return true if author?(req)
  case book["status"]
  when "published" then true
  when "friends" then friend_of_author?(current_reader(req))
  else false
  end
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

def author?(req)
  req["X-Author-Password"].to_s == PASSWORD
end

def find_book(id)
  load_books.find { |book| book["id"] == id }
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
    "tagline" => book["tagline"],
    "cover" => book["cover"],
    "status" => book["status"],
    "updatedAt" => book["updatedAt"],
    "chapterCount" => Array(book["chapters"]).length
  }
end

def now
  Time.now.utc.iso8601
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
    if method == "POST" && parts == ["auth"]
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      if body["password"].to_s == PASSWORD
        json!(res, { "ok" => true })
      else
        json!(res, { "error" => "密碼不對" }, 401)
      end
    elsif method == "POST" && parts == ["readers"]
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      name = body["name"].to_s.strip
      secret = body["password"].to_s
      if name.length < 2 || name.length > 20
        json!(res, { "error" => "請填寫 2 到 20 個字的名字" }, 400)
        next
      end
      if secret.length < 4
        json!(res, { "error" => "密碼至少 4 個字" }, 400)
        next
      end
      users = load_users
      if users.any? { |user| user["name"].to_s.downcase == name.downcase }
        json!(res, { "error" => "這個名字已經有人用了" }, 409)
        next
      end
      salt = SecureRandom.hex(8)
      stamp = now
      user = {
        "id" => SecureRandom.hex(8),
        "name" => name,
        "salt" => salt,
        "passwordHash" => hash_secret(secret, salt),
        "token" => SecureRandom.hex(24),
        "createdAt" => stamp
      }
      users << user
      save_users(users)
      json!(res, { "reader" => public_reader(user), "token" => user["token"], "friendStatus" => "none", "authorName" => site_author_name }, 201)
    elsif method == "POST" && parts == ["readers", "login"]
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      name = body["name"].to_s.strip
      secret = body["password"].to_s
      users = load_users
      index = users.index { |user| user["name"].to_s.downcase == name.downcase }
      user = index ? users[index] : nil
      if user.nil? || user["passwordHash"] != hash_secret(secret, user["salt"])
        json!(res, { "error" => "名字或密碼不對" }, 401)
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
      friends = load_friends
      record = friends.find { |item| item["readerId"] == reader["id"] }
      stamp = now
      if record.nil?
        record = {
          "id" => SecureRandom.hex(8),
          "readerId" => reader["id"],
          "readerName" => reader["name"],
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
        record["updatedAt"] = stamp
      end
      save_friends(friends)
      json!(res, { "friend" => record, "friendStatus" => record["status"] }, 201)
    elsif method == "GET" && parts == ["friends"]
      unless author?(req)
        json!(res, { "error" => "需要作者密碼" }, 401)
        next
      end
      friends = load_friends.sort_by { |item| item["updatedAt"].to_s }.reverse
      json!(res, { "friends" => friends })
    elsif method == "POST" && parts.length == 3 && parts[0] == "friends" && %w[accept reject].include?(parts[2])
      unless author?(req)
        json!(res, { "error" => "需要作者密碼" }, 401)
        next
      end
      friends = load_friends
      index = friends.index { |item| item["id"] == parts[1] }
      if index.nil?
        json!(res, { "error" => "找不到這則申請" }, 404)
        next
      end
      friends[index]["status"] = parts[2] == "accept" ? "accepted" : "rejected"
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
      unless author?(req)
        json!(res, { "error" => "需要作者密碼" }, 401)
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
      book = {
        "id" => SecureRandom.hex(8),
        "title" => title,
        "author" => body["author"].to_s.strip.empty? ? "佚名" : body["author"].to_s.strip,
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
      unless author?(req)
        json!(res, { "error" => "需要作者密碼" }, 401)
        next
      end
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      books = load_books
      index = books.index { |item| item["id"] == parts[1] }
      if index.nil?
        json!(res, { "error" => "找不到這本書" }, 404)
        next
      end
      book = books[index]
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
      book["updatedAt"] = now
      books[index] = book
      save_books(books)
      json!(res, { "book" => book })
    elsif method == "DELETE" && parts.length == 2 && parts[0] == "books"
      unless author?(req)
        json!(res, { "error" => "需要作者密碼" }, 401)
        next
      end
      books = load_books
      before = books.length
      books.reject! { |item| item["id"] == parts[1] }
      if books.length == before
        json!(res, { "error" => "找不到這本書" }, 404)
        next
      end
      save_books(books)
      json!(res, { "ok" => true })
    elsif method == "POST" && parts.length == 3 && parts[0] == "books" && parts[2] == "chapters"
      unless author?(req)
        json!(res, { "error" => "需要作者密碼" }, 401)
        next
      end
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      books = load_books
      index = books.index { |item| item["id"] == parts[1] }
      if index.nil?
        json!(res, { "error" => "找不到這本書" }, 404)
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
      unless author?(req)
        json!(res, { "error" => "需要作者密碼" }, 401)
        next
      end
      body = parse_body(req)
      unless body
        json!(res, { "error" => "無效的請求" }, 400)
        next
      end
      books = load_books
      index = books.index { |item| item["id"] == parts[1] }
      if index.nil?
        json!(res, { "error" => "找不到這本書" }, 404)
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
      unless author?(req)
        json!(res, { "error" => "需要作者密碼" }, 401)
        next
      end
      books = load_books
      index = books.index { |item| item["id"] == parts[1] }
      if index.nil?
        json!(res, { "error" => "找不到這本書" }, 404)
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
      json!(res, { "ok" => true, "book" => books[index] })
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
$stderr.puts "作者密碼：#{PASSWORD}（可用環境變數 BOOKWORMS_PASSWORD 修改）"
server.start
