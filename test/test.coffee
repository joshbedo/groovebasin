mpd = null

results = []
cur_test = null

render = ->
  pass_count = 0
  fail_count = 0
  running_count = 0
  for result in results
    if result.running()
      running_count += 1
    else
      if result.success
        pass_count += 1
      else
        fail_count += 1
  
  $("#tests").html Handlebars.templates.view
    results: results
    pass: pass_count
    fail: fail_count
    running: running_count

nonce = 0
mpd_stack = []
mpdEvent = (expect_calls, event, args..., cb) ->
  active_test = cur_test
  thread_name = "#{event}#{nonce}"
  nonce += 1
  active_test.threads[thread_name] ||= 0
  active_test.threads[thread_name] += parseInt(expect_calls)
  active_mpd = mpd
  mpd[event] args..., (cb_args...) ->
    active_test.threads[thread_name] -= 1
    temp = [cur_test, mpd]
    cur_test = active_test
    mpd = active_mpd
    runTest cb, cb_args...
    [cur_test, mpd] = temp
    render()

lets_test = (name) ->
  cur_test =
    name: name
    success: true
    threads: {}
    running: ->
      sum = 0
      sum += Math.abs(count) for _, count of this.threads
      sum > 0
    status: ->
      if this.success
        if this.running()
          "wait"
        else
          "pass"
      else
        "fail"

  results.push cur_test

  mpd.removeEventListeners 'onError'
  mpdEvent 0, 'onError', (msg) ->
    fail "MPD error: #{msg}"


eq = (a, b) ->
  fail "#{a} != #{b}:\n\n#{printStackTrace().join("\n")}" if a != b

ok = (value) ->
  fail "#{value} is not true:\n\n#{printStackTrace().join("\n")}" if not value

fail = (msg) ->
  cur_test.success = false
  cur_test.details = msg
  throw "TestFail"

tests = [
  ->
    lets_test "connection to mpd"
    mpdEvent 1, 'sendCommand', "status", (msg) ->
      ok /^playlist:/m.test(msg)
      ok /^repeat:/m.test(msg)
      ok /^random:/m.test(msg)
  ->
    lets_test "two instances of mpd"
    mpdEvent 1, 'sendCommand', "status", (msg) ->
      ok /^playlist:/m.test(msg)
      ok /^repeat:/m.test(msg)
      ok /^random:/m.test(msg)
  ->
    lets_test "remove event listeners"
    count = 0
    mpdEvent 1, 'onStatusUpdate', ->
      count += 1
      ok count < 2
      mpd.removeEventListeners 'onStatusUpdate'
      mpdEvent 1, 'onStatusUpdate', ->
        ok true
      mpd.updateStatus()
    mpd.updateStatus()
  ->
    lets_test "get artist list"
    mpdEvent 1, 'onLibraryUpdate', ->
      ok mpd.library.artist_list.length > 1
      mpd.removeEventListeners 'onLibraryUpdate'
 
      rand_index = Math.floor(Math.random()*mpd.library.artist_list.length)
      random_artist = mpd.library.artist_list[rand_index]
      eq mpd.library.artist_table[random_artist.name], random_artist

      lets_test "get songs from artist '#{random_artist.name}'"
      album_tracks = []
      mpdEvent 1, 'onLibraryUpdate', ->
        mpd.removeEventListeners 'onLibraryUpdate'
        ok mpd.library.artist_list.length > 1
        for album_name, album of random_artist.albums
          eq album_name, album.name
          for file, track of album.tracks
            eq track.file, track.file
            ok track.name?
            eq track.artist, random_artist
            eq track.album, album

            # save for next test
            album_tracks.push track

        lets_test "clear playlist 1"
        tracks_to_add = album_tracks[0..2]
        mpdEvent 1, 'onPlaylistUpdate', ->
          mpd.removeEventListeners 'onPlaylistUpdate'
          eq mpd.playlist.item_list.length, 0

          lets_test "add tracks such as '#{tracks_to_add[0].name}' to playlist"
          count = 0
          mpdEvent tracks_to_add.length, 'onPlaylistUpdate', ->
            mpd.removeEventListeners 'onPlaylistUpdate'
            count += 1
            eq mpd.playlist.item_list.length, count

            lets_test "clear playlist 2"
            mpdEvent 1, 'onPlaylistUpdate', ->
              mpd.removeEventListeners 'onPlaylistUpdate'
              eq mpd.playlist.item_list.length, 0
            mpd.clear()
          mpd.queueFile track.file for track in tracks_to_add
        mpd.clear()
      mpd.updateArtistInfo random_artist.name
 
    mpd.updateArtistList()
  ->
    lets_test "get current track"
    mpdEvent 1, 'onStatusUpdate', ->
      mpd.removeEventListeners 'onStatusUpdate'
      ok mpd.status.state is "play" or mpd.status.state is "stop" or mpd.status.state is "pause"

    mpd.updateStatus()
  ->
    lets_test "playback buttons"
    # stop playback, so we know where we're at
    mpdEvent 1, 'onStatusUpdate', ->
      mpd.removeEventListeners 'onStatusUpdate'
      eq mpd.status.state, "stop"
    mpd.stop()
]

runTest = (test, args...) ->
  try
    test(args...)
  catch err
    if err isnt "TestFail"
      cur_test.success = false
      cur_test.details = "#{err}:\n\n#{printStackTrace({e: err}).join("\n")}"
  if not cur_test.running()
    # test is over
    mpd.close()
  render()

runTests = ->
  for test in tests
    mpd = new Mpd()
    runTest(test)

$(document).ready ->
  Handlebars.registerHelper 'hash', (context, options) ->
    ret = ""
    for k,v of context
      ret += options.fn(v)
    ret

  runTests()