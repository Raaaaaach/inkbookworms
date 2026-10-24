#!/usr/bin/env ruby
# frozen_string_literal: true

require "webrick"
require "json"
require "securerandom"
require "fileutils"
require "time"

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
PASSWORD = ENV["BOOKWORMS_PASSWORD"] || "bookworms"
PORT = (ENV["PORT"] || "4567").to_i
BIND = ENV["BIND"] || "0.0.0.0"

FileUtils.mkdir_p(PUBLIC)
FileUtils.mkdir_p(DATA_DIR)
SEED_FILE = File.join(ROOT, "data", "books.json")
if !File.file?(DATA_FILE) && File.file?(SEED_FILE) && File.expand_path(SEED_FILE) != File.expand_path(DATA_FILE)
  FileUtils.cp(SEED_FILE, DATA_FILE)
end
books = load_books
sample = books.find { |item| item["id"] == "sandletters" }
if sample && sample["author"] == "Ra"
  sample["author"] = "JC"
  save_books(books)
end

def load_books
  return [] unless File.file?(DATA_FILE)
  JSON.parse(File.read(DATA_FILE, encoding: "UTF-8"))
rescue JSON::ParserError
  []
end

def save_books(books)
  tmp = "#{DATA_FILE}.tmp"
  File.write(tmp, JSON.pretty_generate(books), encoding: "UTF-8")
  File.rename(tmp, DATA_FILE)
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
    elsif method == "GET" && parts == ["books"]
      books = load_books
      unless author?(req)
        books = books.select { |book| book["status"] == "published" }
      end
      json!(res, { "books" => books.map { |book| public_book(book) } })
    elsif method == "GET" && parts.length == 2 && parts[0] == "books"
      book = find_book(parts[1])
      if book.nil? || (book["status"] != "published" && !author?(req))
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
        "status" => body["status"] == "published" ? "published" : "draft",
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
        book["status"] = body["status"] == "published" ? "published" : "draft"
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
