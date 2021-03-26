require 'active_support'
require 'active_support/core_ext/object'
require 'active_support/core_ext/array'
require 'octokit'
require 'chess'

module Chess
	class Game
		# issue_title: ${{ github.event.issue.title }}
		# token: ${{ secrets.GITHUB_TOKEN }}
		# repository: ${REPOSITORY}
		# issue_number: ${ISSUE_NUMBER}
		# user: ${USER_LOGIN}
		def play(issue_title, token, repository, issue_number, user)
			@preview_headers = [
				::Octokit::Preview::PREVIEW_TYPES[:reactions],
				::Octokit::Preview::PREVIEW_TYPES[:integrations]
			]

			def error_notification(repo_nwo, issue_num, reaction, new_comment_body, e=nil)
				# @octokit.create_issue_reaction(repo_nwo, issue_num, reaction, {accept: @preview_headers})
				@octokit.add_comment(repo_nwo, issue_num, new_comment_body)
				@octokit.close_issue(repo_nwo, issue_num)
				if e.present?
					puts '-----------'
					puts "Exception: #{e}"
					puts '-----------'
				end
			end

			def valid_new_game_request(game)
				issue_title.split('|')&.second.to_s == 'new' &&
				(user == 'timburgan' || game&.over?)
			end

			# Authenticate using GITHUB_TOKEN
			@octokit = Octokit::Client.new(access_token: token)
			@octokit.auto_paginate = true
			@octokit.default_media_type = ::Octokit::Preview::PREVIEW_TYPES[:integrations]
			# Show we've got eyes on the triggering comment.
			@octokit.create_issue_reaction(
				repository,
				issue_number,
				'rocket',
				{accept: @preview_headers}
			)

			#
			# Parse the issue title.
			# ------------------------
			begin
				# validate we can parse title Chess|new|e3c2|1
				title_split = issue_title.split('|')
				chess_game_num   = title_split&.fourth || issue_number.to_s
				chess_game_title = title_split&.first.to_s + chess_game_num
				chess_game_cmd   = title_split&.second.to_s
				chess_user_move  = title_split&.third.to_s
				raise StandardError.new 'chess_game_title is blank' if chess_game_title.blank?
				raise StandardError.new 'chess_user_move is blank'	if chess_user_move.blank? && chess_game_cmd == 'move'
				raise StandardError.new 'new|move are the only allowed commands' unless ['new','move'].include? chess_game_cmd
			rescue StandardError => e
				comment_text = "@#{user} The game title or move was unable to be parsed."
				error_notification(repository, issue_number, 'confused', comment_text, e)
				exit(0)
			end

			game_data_path = "chess_games/chess.pgn"
			tmp_filename = "/tmp/chess.pgn"
			game = nil
			game_content = nil

			#
			# Get the contents of the game board.
			# ---------------------------------------
			begin
				game_content_raw = @octokit.contents(
					repository,
					path: game_data_path
				)

				game_content = Base64.decode64(game_content_raw&.content.to_s) unless game_content_raw&.content.to_s.blank?
			rescue StandardError => e
				# no file exists... so no game... so... go ahead and create it
				game = Chess::Game.new
			else
				game = if valid_new_game_request(game) || game.present?
					Chess::Game.new
				else
					#
					# Game is in progress. Load the game board.
					# ---------------------------------------
					begin
						## Load the current game
						File.write tmp_filename, game_content
						Chess::Game.load_pgn tmp_filename
					rescue StandardError => e
						comment_text = "@#{user} Game data couldn't loaded: #{game_data_path}"
						error_notification(repository, issue_number, 'confused', comment_text, e)
						exit(0)
					end
				end
			end

			if valid_new_game_request(game) && game_content_raw.present?
				begin
					@octokit.delete_contents(
						repository,
						game_data_path,
						"@#{user} delete to allow new game",
						game_content_raw&.sha,
						branch: 'master',
					)
				rescue StandardError => e
					comment_text = "@#{user} Game data couldn't be deleted: #{game_data_path}"
					error_notification(repository, issue_number, 'confused', comment_text, e)
					exit(0)
				end
			end

			begin
				issues = @octokit.list_issues(
					repository,
					state: 'closed',
					accept: @preview_headers
				)&.select{ |issue| issue&.reactions.confused == 0 }

			rescue StandardError => e
				# don't exit, if these can't be retrieved. Allow play to continue.
			end

			if chess_game_cmd == 'move'
				#
				# Share the play. Exit if user just had the prior move.
				# Need to filter out and PRs and other issues though.
				#-------------------
				i = 0
				issues&.each do |issue|
					break if issue.title.start_with? 'chess|new'
					if issue.title.start_with?('chess|move|') && repository == 'timburgan/timburgan'
						if issue.user.login == user
							comment_text = "@#{user} Slow down! You _just_ moved, so can't immediately take the next turn. Invite a friend to take the next turn! [Share on Twitter...](https://twitter.com/share?text=I'm+playing+chess+on+a+GitHub+Profile+Readme!+I+just+moved.+You+have+the+next+move+at+https://github.com/timburgan)"
							error_notification(repository, issue_number, 'confused', comment_text, e)
							exit(0)
						end
						i += 1
					end
					break if i >= 1
				end

					#
				# Perform Move
				# ---------------------------------------
				begin
					game.move(chess_user_move) # ie move('e2e4', …, 'b1c3')
				rescue Chess::IllegalMoveError => e
					comment_text = "@#{user} Whaaa.. '#{chess_user_move}' is an invalid move! Usually this is because someone squeezed a move in just before you."
					error_notification(repository, issue_number, 'confused', comment_text, e)
					exit(0)
				end

				#
				# Save the game board.
				# ---------------------------------------
				begin
					@octokit.create_contents(
						repository,
						game_data_path,
						"#{user} move #{chess_user_move}",
						game.pgn.to_s,
						branch: 'master',
						sha:    game_content_raw&.sha
					)
				rescue StandardError => e
					comment_text = "@#{user} Couldn't save game data. Sorry."
					error_notification(repository, issue_number, 'confused', comment_text, e)
					exit(0)
				end

					

				#
				# Game over thanks for playing.
				# ---------------------------------------
				if game.over?
					# add label = end
					#@octokit.add_labels_to_an_issue(repository, issue_number, ["game-over"])
					game_stats = { moves: 0, players: [], start_time: nil, end_time: nil }
					issues&.each do |issue|
						break if issue.title.start_with? 'chess|new'
						if game_stats[:moves] == 0
							game_stats[:end_time] = issue.created_at
						end
						game_stats[:moves] += 1
						if repository == 'timburgan/timburgan'
							game_stats[:players].push "@#{issue.user.login}"
						else
							game_stats[:players].push "#{issue.user.login}"
						end
						game_stats[:start_time] = issue.created_at
					end
					game_stats[:players] = game_stats[:players]&.uniq
					hours = (game_stats[:start_time] - game_stats[:end_time]).to_i.abs / 3600
					@octokit.add_comment(
						repository,
						issue_number,
						"That's game over! Thank you for playing that chess game. That game had #{
							game_stats[:moves]
						} moves, #{
							game_stats[:players]&.length
						} players, and went for #{hours} hours. Let's play again at https://github.com/timburgan.\n\nPlayers that game: #{
							game_stats[:players].join(', ')
						}"
					)
				end
			end

			text = "I'm playing chess on a GitHub Profile Readme!I just moved. You have the next move at https://github.com/timburgan"
			encoded_text = text.split(' ').join('+')
			@octokit.add_comment(
				repository,
				issue_number,
				"@#{user} Done. View back at https://github.com/timburgan\n\nAsk a friend to take the next move: [Share on Twitter...](https://twitter.com/share?text=#{encoded_text})"
			)					
			@octokit.close_issue(repository, issue_number)

			#
			# Update timburgan/timburgan/README.md
			# ---------------------------------------

			# visually represent the board
			# generate new comment links
			#	 - and "what possible valid moves are for each piece"

			cols = ('a'..'h').to_a
			rows = (1..8).to_a

			# list squares on the board - format a1, a2, a3, b1, b2, b3 etc
			squares = []
			cols.each do |col|
				rows.each do |row|
					squares.push "#{col}#{row}"
				end
			end

			# combine squares with where they	can MOVE to
			next_move_combos = squares.map { |from| {from: from, to: squares} }

			fake_game = if chess_game_cmd == 'move'
				File.write tmp_filename, game.pgn.to_s
				Chess::Game.load_pgn tmp_filename
			else
				Chess::Game.new
			end

			# delete squares not valid for next move
			good_moves = []
			next_move_combos.each do |square|
				square[:to].each do |to|
					move_command = "#{square[:from]}#{to}"
					fake_game_tmp = if chess_game_cmd == 'move'
						File.write tmp_filename, fake_game.pgn.to_s
						Chess::Game.load_pgn tmp_filename
					else
						Chess::Game.new
					end
					begin
						fake_game_tmp.move move_command
					rescue Chess::IllegalMoveError => e
						# puts "move: #{move_command} (bad)"
					else
						# puts "move: #{move_command} (ok)"
						if good_moves.select{ |move| move[:from] == square[:from] }.blank?
							good_moves.push({ from: square[:from], to: [to] })
						else
							good_moves.map do |move|
								if move[:from] == square[:from]
									{
										from: move[:from],
										to:	 move[:to].push(to)
									}
								else
									move
								end
							end
						end
					end
				end
			end

			game_state = case game.status.to_s
				when 'in_progress'
					'Game is in progress.'
				when 'white_won'
					'Game won by white (hollow) with a checkmate.'
				when 'black_won'
					'Game won by black (solid) with a checkmate.'
				when 'white_won_resign'
					'Game won by white (hollow) by resign.'
				when 'black_won_resign'
					'Game won by black (solid) by resign.'
				when 'stalemate'
					'Game was a draw due to stalemate.'
				when 'insufficient_material'
					'Game was a draw due to insufficient material to checkmate.'
				when 'fifty_rule_move'
					'Game was a draw due to fifty rule move.'
				when 'threefold_repetition'
					'Game was a draw due to threshold repetition.'
				else
					'Game terminated. Something went wrong.'
				end

			new_readme = <<~HTML

				## Tim's Community Chess Tournament

				**#{game_state}** This is open to ANYONE to play the next move. That's the point. :wave:	It's your turn! Move a #{(game.board.active_color) ? 'black (solid)' : 'white (hollow)'} piece.

			HTML

			board = {
				"8": { a: 56, b: 57, c: 58, d: 59, e: 60, f: 61, g: 62, h: 63 },
				"7": { a: 48, b: 49, c: 50, d: 51, e: 52, f: 53, g: 54, h: 55 },
				"6": { a: 40, b: 41, c: 42, d: 43, e: 44, f: 45, g: 46, h: 47 },
				"5": { a: 32, b: 33, c: 34, d: 35, e: 36, f: 37, g: 38, h: 39 },
				"4": { a: 24, b: 25, c: 26, d: 27, e: 28, f: 29, g: 30, h: 31 },
				"3": { a: 16, b: 17, c: 18, d: 19, e: 20, f: 21, g: 22, h: 23 },
				"2": { a:  8, b:  9, c: 10, d: 11, e: 12, f: 13, g: 14, h: 15 },
				"1": { a:  0, b:  1, c:  2, d:  3, e:  4, f:  5, g:  6, h:  7 },
			}

			new_readme.concat "|   | A | B | C | D | E | F | G | H |\n"
			new_readme.concat "| - | - | - | - | - | - | - | - | - |\n"
			(1..8).to_a.reverse.each_with_index do |row|
				a = "![](https://raw.githubusercontent.com/#{repository}/master/images/chess_pieces/#{ (game.board[board[:"#{row}"][:a]] || 'blank').to_s }.png)"
				b = "![](https://raw.githubusercontent.com/#{repository}/master/images/chess_pieces/#{ (game.board[board[:"#{row}"][:b]] || 'blank').to_s }.png)"
				c = "![](https://raw.githubusercontent.com/#{repository}/master/images/chess_pieces/#{ (game.board[board[:"#{row}"][:c]] || 'blank').to_s }.png)"
				d = "![](https://raw.githubusercontent.com/#{repository}/master/images/chess_pieces/#{ (game.board[board[:"#{row}"][:d]] || 'blank').to_s }.png)"
				e = "![](https://raw.githubusercontent.com/#{repository}/master/images/chess_pieces/#{ (game.board[board[:"#{row}"][:e]] || 'blank').to_s }.png)"
				f = "![](https://raw.githubusercontent.com/#{repository}/master/images/chess_pieces/#{ (game.board[board[:"#{row}"][:f]] || 'blank').to_s }.png)"
				g = "![](https://raw.githubusercontent.com/#{repository}/master/images/chess_pieces/#{ (game.board[board[:"#{row}"][:g]] || 'blank').to_s }.png)"
				h = "![](https://raw.githubusercontent.com/#{repository}/master/images/chess_pieces/#{ (game.board[board[:"#{row}"][:h]] || 'blank').to_s }.png)"

				# a = game.board[board[:"#{row}"][:a]]
				# b = game.board[board[:"#{row}"][:b]]
				# c = game.board[board[:"#{row}"][:c]]
				# d = game.board[board[:"#{row}"][:d]]
				# e = game.board[board[:"#{row}"][:e]]
				# f = game.board[board[:"#{row}"][:f]]
				# g = game.board[board[:"#{row}"][:g]]
				# h = game.board[board[:"#{row}"][:h]]

				new_readme.concat "| #{row} | #{a} | #{b} | #{c} | #{d} | #{e} | #{f} | #{g} | #{h} |\n"
			end

			if game.over?
				new_readme.concat <<~HTML

					## Play again? [![](https://raw.githubusercontent.com/#{repository}/master/chess_images/new_game.png)](https://github.com/#{repository}/issues/new?title=chess%7Cnew)

				HTML
			else
				new_readme.concat <<~HTML

					#### **#{(game.board.active_color) ? 'BLACK (solid)' : 'WHITE (hollow)'}:** It's your move... to choose _where_ to move..

					| FROM | TO - _just click one of the links_ :) |
					| ---- | -- |
				HTML

				good_moves.each do |move|
					new_readme.concat "| **#{
						move[:from].upcase
					}** | #{
						move[:to].map{
							|a| "[#{a.upcase}](https://github.com/#{repository}/issues/new?title=chess%7Cmove%7C#{move[:from]}#{a}%7C#{chess_game_num}&body=Just+push+%27Submit+new+issue%27.+You+don%27t+need+to+do+anything+else.)"
						}.join(' , ')
					} |\n"
				end
			end

			new_readme.concat <<~HTML

				Ask a friend to take the next move: [Share on Twitter...](https://twitter.com/share?text=I'm+playing+chess+on+a+GitHub+Profile+Readme!+Can+you+please+take+the+next+move+at+https://github.com/timburgan)

				**How this works**

				When you click a link, it opens a GitHub Issue with the required pre-populated text. Just push "Create New Issue". That will trigger a [GitHub Actions](https://github.blog/2020-07-03-github-action-hero-casey-lee/#getting-started-with-github-actions) workflow that'll update my GitHub Profile _README.md_ with the new state of the board.

				**Notice a problem?**

				Raise an [issue](https://github.com/#{repository}/issues), and include the text _cc @timburgan_.

				**Last few moves, this game**

				| Move	| Who |
				| ----- | --- |
			HTML

			new_readme.concat "| #{chess_user_move[0..1].to_s.upcase} to #{chess_user_move[2..3].to_s.upcase} | [@#{user}](https://github.com/#{user}) |\n"

			if issues.present? # just in case, the API is down, or there's no response, don't let that prevent the game rendering
				i = 0
				issues.each do |issue|
					break if issue.title.start_with? 'chess|new'
					if issue.title.start_with? 'chess|move|'
						from = issue.title&.split('|')&.third.to_s[0..1].to_s.upcase
						to = issue.title&.split('|')&.third.to_s[2..3].to_s.upcase
						who = issue.user.login
						i += 1
						new_readme.concat "| #{from} to #{to} | [@#{who}](https://github.com/#{who}) |\n"
					end
					break if i >= 4
				end
			else
				new_readme.concat "| ¯\\_(ツ)_/¯ | History temporarily unavailable. |\n"
			end

			new_readme.concat <<~HTML

				**Top 20 Leaderboard: Most moves across all games, except me.**

				| Moves | Who |
				| ----- | --- |
			HTML

			if issues.present?
				moves = issues.select{
					|issue| issue.title.start_with? 'chess|move|'}.map{ |issue| issue.user.login }&.group_by(&:itself)&.except("timburgan")&.transform_values(&:size).sort_by{|name,moves| moves }.reverse[0..19]
				moves.each do |move|
					new_readme.concat "| #{move[1]} | [@#{move[0]}](https://github.com/#{move[0]}) |\n"
				end
			else
				new_readme.concat "| ¯\\_(ツ)_/¯ | History temporarily unavailable. |\n"
			end

			#
			# Update the game with next moves.
			# ---------------------------------------
			begin
				current_readme_sha = @octokit.contents(
					repository,
					path: 'README.md'
				)&.sha

				@octokit.create_contents(
					repository,
					'README.md',
					"#{user} move #{chess_user_move}",
					new_readme,
					branch: 'master',
					sha:    current_readme_sha
				)
			rescue StandardError => e
				comment_text = "@#{user} Couldn't update render of the game board. Move *was* saved, however."
				error_notification(repository, issue_number, 'confused', comment_text, e)
				exit(0)
			end
		end
	end
end
