class PostList extends Class
	constructor: ->
		@item_list = new ItemList(Post, "key")
		@posts = @item_list.items
		@need_update = true
		@directories = []
		@loaded = false
		@filter_post_ids = null
		@limit = 10

	queryComments: (post_uris, cb) =>
		query = "
			SELECT
			 post_uri, comment.body, comment.date_added, comment.comment_id, json.cert_auth_type, json.cert_user_id, json.user_name, json.hub, json.directory, json.site
			FROM
			 comment
			LEFT JOIN json USING (json_id)
			WHERE
			 ? AND date_added < #{Time.timestamp()+120}
			ORDER BY date_added DESC
		"
		return Page.cmd "dbQuery", [query, {post_uri: post_uris}], cb

	queryLikes: (post_uris, cb) =>
		query = "SELECT post_uri, COUNT(*) AS likes FROM post_like WHERE ? GROUP BY post_uri"
		return Page.cmd "dbQuery", [query, {post_uri: post_uris}], cb

	queryReposts: (post_uris, cb) =>
		query = "SELECT repost_uri AS post_uri, COUNT(*) AS reposts FROM repost WHERE ? GROUP BY repost_uri"
		return Page.cmd "dbQuery", [query, {post_uri: post_uris}], cb

	queryRepostOrigin: (reposts_origins, cb) =>
		post_directories = []
		post_ids = []

		for item in reposts_origins
			do (item) ->
				post_directories.push("data/users/" + item.repost_uri.split('_')[0])
				post_ids.push(item.repost_uri.split('_')[1])

		query = "
			SELECT * FROM post
			LEFT JOIN json ON (post.json_id = json.json_id)
			WHERE
			  post_id IN #{Text.sqlIn(post_ids)} AND directory IN #{Text.sqlIn(post_directories)}
		"
		return Page.cmd "dbQuery", [query], cb

	update: =>
		@need_update = false

		param  = {}
		if @directories == "all"
			where = "WHERE post_id IS NOT NULL AND date_added < #{Time.timestamp()+120} "
		else
			where = "WHERE directory IN #{Text.sqlIn(@directories)} AND post_id IS NOT NULL AND date_added < #{Time.timestamp()+120} "

		if @filter_post_ids
			where += "AND post_id IN #{Text.sqlIn(@filter_post_ids)} "

		if Page.local_storage.settings.hide_hello_zerome
			where += "AND post_id > 1 "

		query = "
			SELECT * FROM post
			LEFT JOIN json ON (post.json_id = json.json_id)
			#{where}

			UNION ALL

			SELECT * FROM repost
			LEFT JOIN json ON (repost.json_id = json.json_id)
			#{where}

			ORDER BY date_added DESC
			LIMIT #{@limit+1}
		"
		@logStart "Update"
		Page.cmd "dbQuery", [query, param], (rows) =>
			items = []
			post_uris = []
			reposts_origins = {}

			for row, i in rows
				row["key"] = row["site"]+"-"+row["directory"].replace("data/users/", "")+"_"+row["post_id"]
				row["post_uri"] = row["directory"].replace("data/users/", "") + "_" + row["post_id"]
				if row["repost_uri"] and row["repost_uri"] != null
					reposts_origins[row["repost_uri"]] = row
					reposts_origins[row["repost_uri"]].repost_id = i
				else
					post_uris.push(row["post_uri"])

			# Fetch original posts from reposts (get original bodies and other data by "repost_uri" from repost).
			# Repost doesn't contains post body (it have only uri to origin).

			@queryRepostOrigin Object.values(reposts_origins), (repost_origin_rows) =>
				repost_origin_db = {}

				for row in repost_origin_rows
					row["key"] = row["site"]+"-"+row["directory"].replace("data/users/", "")+"_"+row["post_id"]
					row["post_uri"] = row["directory"].replace("data/users/", "") + "_" + row["post_id"]
					repost = reposts_origins[row["post_uri"]]

					# Put some metadata from repost (eg. who did this repost)
					row["is_repost"] = true
					row["key"] = repost.key
					row["reposted_by_hub"] = repost["hub"]
					row["reposted_by_directory"] = repost["directory"]
					row["reposted_by_address"] = repost["cert_user_id"]
					row["repost_uri"] = repost["post_uri"]
					rows[repost.repost_id] = row

					post_uris.push(row["post_uri"])

				@item_list.sync(rows)
				Page.projector.scheduleRender()

				# Query comments, likes and reposts count only after quering reposts origins,
				# because we want to retrieve this info from the original post (not from the repost itself).

				# Get comments for latest posts
				@queryComments post_uris, (comment_rows) =>
					comment_db = {}  # {Post id: posts}
					for comment_row in comment_rows
						comment_db[comment_row.site+"/"+comment_row.post_uri] ?= []
						comment_db[comment_row.site+"/"+comment_row.post_uri].push(comment_row)
					for row in rows
						row["comments"] = comment_db[row.site+"/"+row.post_uri]
						if @filter_post_ids?.length == 1 and row.post_id == parseInt(@filter_post_ids[0])
							row.selected = true
					@item_list.sync(rows)
					@loaded = true
					@logEnd "Update"
					Page.projector.scheduleRender()

					if @posts.length > @limit
						@addScrollwatcher()

				@queryLikes post_uris, (like_rows) =>
					like_db = {}
					for like_row in like_rows
						like_db[like_row["post_uri"]] = like_row["likes"]

					for row in rows
						row["likes"] = like_db[row["post_uri"]]
					@item_list.sync(rows)
					Page.projector.scheduleRender()

				@queryReposts post_uris, (repost_rows) =>
					repost_db = {}
					for repost_row in repost_rows
						repost_db[repost_row["post_uri"]] = repost_row["reposts"]

					for row in rows
						row["reposts"] = repost_db[row["post_uri"]]
					@item_list.sync(rows)
					Page.projector.scheduleRender()

	handleMoreClick: =>
		@limit += 10
		@update()
		return false

	addScrollwatcher: =>
		setTimeout ( =>
			# Remove previous scrollwatchers for same item
			for item, i in Page.scrollwatcher.items
				if item[1] == @tag_more
					Page.scrollwatcher.items.splice(i, 1)
					break
			Page.scrollwatcher.add @tag_more, (tag) =>
				if tag.getBoundingClientRect().top == 0
					return
				@limit += 10
				@need_update = true
				Page.projector.scheduleRender()
		), 2000


	storeMoreTag: (elem) =>
		@tag_more = elem

	render: =>
		if @need_update then @update()
		if not @posts.length
			if not @loaded
				return null
			else
				return h("div.post-list", [
					h("div.post-list-empty", {enterAnimation: Animation.slideDown, exitAnimation: Animation.slideUp}, [
						h("h2", "No posts yet"),
						h("a", {href: "?Users", onclick: Page.handleLinkClick}, "Let's follow some users!")
					])
				])

		return [
			h("div.post-list", @posts[0..@limit].map (post) =>
				try
					post.render()
				catch err
					h("div.error", ["Post render error:", err.message])
					Debug.formatException(err)
			),
			if @posts.length > @limit
				h("a.more.small", {href: "#More", onclick: @handleMoreClick, enterAnimation: Animation.slideDown, exitAnimation: Animation.slideUp, afterCreate: @storeMoreTag}, "Show more posts...")
		]

window.PostList = PostList
