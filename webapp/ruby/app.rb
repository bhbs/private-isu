require 'sinatra/base'
require 'mysql2'
require 'rack-flash'
require 'shellwords'
require 'rack/session/dalli'
require 'fileutils'
require 'openssl'
require 'dalli'

module Isuconp
  class App < Sinatra::Base
    use Rack::Session::Dalli, autofix_keys: true, secret: ENV['ISUCONP_SESSION_SECRET'] || 'sendagaya', memcache_server: ENV['ISUCONP_MEMCACHED_ADDRESS'] || 'localhost:11211'
    use Rack::Flash
    set :public_folder, File.expand_path('../../public', __FILE__)

    # refs: https://github.com/advisories/GHSA-hxx2-7vcw-mqr3
    set :host_authorization, { permitted_hosts: [] }

    UPLOAD_LIMIT = 10 * 1024 * 1024 # 10mb

    POSTS_PER_PAGE = 20

    IMAGE_DIR = File.expand_path('../../public/image', __FILE__)

    MAKE_POSTS_MEMBERS = 'p.id, p.user_id, p.body, p.created_at, p.mime, p.comment_count, u.account_name'

    helpers do
      def config
        @config ||= {
          db: {
            host: ENV['ISUCONP_DB_HOST'] || 'localhost',
            port: ENV['ISUCONP_DB_PORT'] && ENV['ISUCONP_DB_PORT'].to_i,
            username: ENV['ISUCONP_DB_USER'] || 'root',
            password: ENV['ISUCONP_DB_PASSWORD'],
            database: ENV['ISUCONP_DB_NAME'] || 'isuconp',
          },
        }
      end

      def db
        return Thread.current[:isuconp_db] if Thread.current[:isuconp_db]
        client = Mysql2::Client.new(
          host: config[:db][:host],
          port: config[:db][:port],
          username: config[:db][:username],
          password: config[:db][:password],
          database: config[:db][:database],
          encoding: 'utf8mb4',
          reconnect: true,
        )
        client.query_options.merge!(symbolize_keys: true, database_timezone: :local, application_timezone: :local)
        Thread.current[:isuconp_db] = client
        client
      end

      def memcached
        return Thread.current[:isuconp_memcached] if Thread.current[:isuconp_memcached]
        client = Dalli::Client.new(
          ENV['ISUCONP_MEMCACHED_ADDRESS'] || 'localhost:11211'
        )
        Thread.current[:isuconp_memcached] = client
        client
      end

      def db_initialize
        sql = []
        sql << 'DELETE FROM users WHERE id > 1000'
        sql << 'DELETE FROM posts WHERE id > 10000'
        sql << 'DELETE FROM comments WHERE id > 100000'
        sql << 'UPDATE users SET del_flg = 0'
        sql << 'UPDATE users SET del_flg = 1 WHERE id % 50 = 0'
        sql << "UPDATE posts SET comment_count = (SELECT COUNT(*) FROM comments WHERE comments.post_id = posts.id)"
        sql.each do |s|
          db.prepare(s).execute
        end
      end

      def try_login(account_name, password)
        user = db.prepare('SELECT * FROM users WHERE account_name = ? AND del_flg = 0').execute(account_name).first

        if user && calculate_passhash(user[:account_name], password) == user[:passhash]
          return user
        else
          return nil
        end
      end

      def validate_user(account_name, password)
        if !(/\A[0-9a-zA-Z_]{3,}\z/.match(account_name) && /\A[0-9a-zA-Z_]{6,}\z/.match(password))
          return false
        end

        return true
      end

      def digest(src)
        return OpenSSL::Digest::SHA512.hexdigest(src)
      end

      def calculate_salt(account_name)
        digest account_name
      end

      def calculate_passhash(account_name, password)
        digest "#{password}:#{calculate_salt(account_name)}"
      end

      def get_session_user()
        if session[:user]
          db.prepare('SELECT * FROM `users` WHERE `id` = ?').execute(
            session[:user][:id]
          ).first
        else
          nil
        end
      end

      def make_posts(results, all_comments: false)
        posts = results.to_a

        count_keys = posts.map{|post| "comments.#{post[:id]}.count"}
        cached_counts = memcached.get_multi(count_keys)

        comments_query_base = 'SELECT * FROM `comments` WHERE `post_id` = ? ORDER BY `created_at` DESC'
        comments_query_base += ' LIMIT 3' unless all_comments
        comments_stmt = db.prepare(comments_query_base)

        posts.each do |post|
          cached_comments = memcached.get("comments.#{post[:id]}.#{all_comments.to_s}")
          if cached_comments
            post[:comments] = cached_comments
          else
            comments = comments_stmt.execute(post[:id]).to_a
            comments.each do |comment|
              comment[:user] = { account_name: comment[:account_name] }
            end
            post[:comments] = comments.reverse
            post[:comments] = post[:comments].map { |comment| normalize_comment(comment) }
            memcached.set("comments.#{post[:id]}.#{all_comments.to_s}", post[:comments], 10)
          end

          post[:user] = {
            account_name: post[:account_name],
          }
        end

        posts
      end

      def normalize_comment(comment)
        return { user: { account_name: '' }, comment: '' } if comment.nil?

        comment = comment.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k } if comment.respond_to?(:transform_keys)

        user = comment[:user]
        if !user.is_a?(Hash)
          user = {}
        else
          user = user.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
        end

        account_name = user[:account_name] || comment[:account_name]
        user[:account_name] ||= account_name || ''

        comment[:user] = user
        comment
      end

      def image_url(post)
        ext = ""
        if post[:mime] == "image/jpeg"
          ext = ".jpg"
        elsif post[:mime] == "image/png"
          ext = ".png"
        elsif post[:mime] == "image/gif"
          ext = ".gif"
        end

        "/image/#{post[:id]}#{ext}"
      end
    end

    get '/initialize' do
      db_initialize
      return 200
    end

    get '/login' do
      if get_session_user()
        redirect '/', 302
      end
      erb :login, layout: :layout, locals: { me: nil }
    end

    post '/login' do
      if get_session_user()
        redirect '/', 302
      end

      user = try_login(params['account_name'], params['password'])
      if user
        session[:user] = {
          id: user[:id]
        }
        session[:csrf_token] = SecureRandom.hex(16)
        redirect '/', 302
      else
        flash[:notice] = 'アカウント名かパスワードが間違っています'
        redirect '/login', 302
      end
    end

    get '/register' do
      if get_session_user()
        redirect '/', 302
      end
      erb :register, layout: :layout, locals: { me: nil }
    end

    post '/register' do
      if get_session_user()
        redirect '/', 302
      end

      account_name = params['account_name']
      password = params['password']

      validated = validate_user(account_name, password)
      if !validated
        flash[:notice] = 'アカウント名は3文字以上、パスワードは6文字以上である必要があります'
        redirect '/register', 302
        return
      end

      user = db.prepare('SELECT 1 FROM users WHERE `account_name` = ?').execute(account_name).first
      if user
        flash[:notice] = 'アカウント名がすでに使われています'
        redirect '/register', 302
        return
      end

      query = 'INSERT INTO `users` (`account_name`, `passhash`) VALUES (?,?)'
      db.prepare(query).execute(
        account_name,
        calculate_passhash(account_name, password)
      )

      session[:user] = {
        id: db.last_id
      }
      session[:csrf_token] = SecureRandom.hex(16)
      redirect '/', 302
    end

    get '/logout' do
      session.delete(:user)
      redirect '/', 302
    end

    get '/' do
      me = get_session_user()

      results = db.query(<<~SQL)
        SELECT
          #{MAKE_POSTS_MEMBERS}
        FROM (
            SELECT id, user_id, body, created_at, mime, comment_count
            FROM posts
            ORDER BY created_at DESC
            LIMIT 40
        ) AS p
        JOIN users AS u ON p.user_id = u.id
        WHERE u.del_flg = 0
        ORDER BY p.created_at DESC
        LIMIT #{POSTS_PER_PAGE};
      SQL
      posts = make_posts(results)

      erb :index, layout: :layout, locals: { posts: posts, me: me }
    end

    get '/@:account_name' do
      user = db.prepare('SELECT * FROM `users` WHERE `account_name` = ? AND `del_flg` = 0').execute(
        params[:account_name]
      ).first

      if user.nil?
        return 404
      end

      results = db.prepare(<<~SQL).execute(user[:id])
        SELECT #{MAKE_POSTS_MEMBERS}
        FROM `posts` AS p FORCE INDEX (posts_user_idx) JOIN `users` AS u ON (p.user_id=u.id)
        WHERE p.user_id = ? AND u.del_flg = 0
        ORDER BY p.created_at DESC
        LIMIT #{POSTS_PER_PAGE}
      SQL
      posts = make_posts(results)

      comment_count = db.prepare('SELECT COUNT(*) AS count FROM `comments` WHERE `user_id` = ?').execute(
        user[:id]
      ).first[:count]

      post_ids = db.prepare('SELECT `id` FROM `posts` WHERE `user_id` = ?').execute(
        user[:id]
      ).map{|post| post[:id]}
      post_count = post_ids.length

      commented_count = 0
      if post_count > 0
        placeholder = (['?'] * post_ids.length).join(",")
        commented_count = db.prepare("SELECT COUNT(*) AS count FROM `comments` WHERE `post_id` IN (#{placeholder})").execute(
          *post_ids
        ).first[:count]
      end

      me = get_session_user()

      erb :user, layout: :layout, locals: { posts: posts, user: user, post_count: post_count, comment_count: comment_count, commented_count: commented_count, me: me }
    end

    get '/posts' do
      max_created_at = params['max_created_at']
      if max_created_at.nil?
        results = db.prepare(<<~SQL).execute
        SELECT #{MAKE_POSTS_MEMBERS}
        FROM `posts` AS p JOIN `users` AS u ON (p.user_id=u.id)
        WHERE u.del_flg = 0
        ORDER BY p.created_at DESC
        LIMIT #{POSTS_PER_PAGE}
        SQL
      else
        results = db.prepare(<<~SQL).execute(Time.iso8601(max_created_at).localtime)
          SELECT #{MAKE_POSTS_MEMBERS}
          FROM `posts` AS p JOIN `users` AS u ON (p.user_id=u.id)
          WHERE p.created_at < ? AND u.del_flg = 0
          ORDER BY p.created_at DESC
          LIMIT #{POSTS_PER_PAGE}
        SQL
      end
      posts = make_posts(results)

      erb :posts, layout: false, locals: { posts: posts }
    end

    get '/posts/:id' do
      results = db.prepare(<<~SQL).execute(params[:id])
        SELECT #{MAKE_POSTS_MEMBERS}
        FROM `posts` AS p JOIN `users` AS u ON (p.user_id=u.id)
        WHERE p.id = ? AND u.del_flg = 0
      SQL
      posts = make_posts(results, all_comments: true)

      return 404 if posts.length == 0

      post = posts[0]

      me = get_session_user()

      erb :post, layout: :layout, locals: { post: post, me: me }
    end

    post '/' do
      me = get_session_user()

      if me.nil?
        redirect '/login', 302
      end

      if params['csrf_token'] != session[:csrf_token]
        return 422
      end

      if params['file']
        mime, ext = '', ''
        # 投稿のContent-Typeからファイルのタイプを決定する
        if params["file"][:type].include? "jpeg"
          mime, ext = "image/jpeg", "jpg"
        elsif params["file"][:type].include? "png"
          mime, ext = "image/png", "png"
        elsif params["file"][:type].include? "gif"
          mime, ext = "image/gif", "gif"
        else
          flash[:notice] = '投稿できる画像形式はjpgとpngとgifだけです'
          redirect '/', 302
        end

        if params['file'][:tempfile].size > UPLOAD_LIMIT
          flash[:notice] = 'ファイルサイズが大きすぎます'
          redirect '/', 302
        end

        query = 'INSERT INTO `posts` (`user_id`, `mime`, `imgdata`, `body`) VALUES (?,?,?,?)'
        db.prepare(query).execute(
          me[:id],
          mime,
          '',
          params["body"],
        )
        pid = db.last_id

        imgfile = IMAGE_DIR + "/#{pid}.#{ext}"
        FileUtils.mv(params['file'][:tempfile], imgfile)
        FileUtils.chmod(0644, imgfile)

        redirect "/posts/#{pid}", 302
      else
        flash[:notice] = '画像が必須です'
        redirect '/', 302
      end
    end

    get '/image/:id.:ext' do
      if params[:id].to_i == 0
        return ""
      end

      post = db.prepare('SELECT * FROM `posts` WHERE `id` = ?').execute(params[:id].to_i).first

      if (params[:ext] == "jpg" && post[:mime] == "image/jpeg") ||
          (params[:ext] == "png" && post[:mime] == "image/png") ||
          (params[:ext] == "gif" && post[:mime] == "image/gif")
        headers['Content-Type'] = post[:mime]

        imgfile = IMAGE_DIR + "/#{post[:id]}.#{params[:ext]}"
        f = File.open(imgfile, "w")
        f.write(post[:imgdata])
        f.close()
        return post[:imgdata]
      end

      return 404
    end

    post '/comment' do
      me = get_session_user()

      if me.nil?
        redirect '/login', 302
      end

      if params["csrf_token"] != session[:csrf_token]
        return 422
      end

      unless /\A[0-9]+\z/.match(params['post_id'])
        return 'post_idは整数のみです'
      end
      post_id = params['post_id']

      query = 'INSERT INTO `comments` (`post_id`, `user_id`, `comment`) VALUES (?,?,?)'
      db.prepare(query).execute(
        post_id,
        me[:id],
        params['comment']
      )

      redirect "/posts/#{post_id}", 302
    end

    get '/admin/banned' do
      me = get_session_user()

      if me.nil?
        redirect '/login', 302
      end

      if me[:authority] == 0
        return 403
      end

      users = db.query('SELECT * FROM `users` WHERE `authority` = 0 AND `del_flg` = 0 ORDER BY `created_at` DESC')

      erb :banned, layout: :layout, locals: { users: users, me: me }
    end

    post '/admin/banned' do
      me = get_session_user()

      if me.nil?
        redirect '/', 302
      end

      if me[:authority] == 0
        return 403
      end

      if params['csrf_token'] != session[:csrf_token]
        return 422
      end

      query = 'UPDATE `users` SET `del_flg` = ? WHERE `id` = ?'

      params['uid'].each do |id|
        db.prepare(query).execute(1, id.to_i)
      end

      redirect '/admin/banned', 302
    end
  end
end
