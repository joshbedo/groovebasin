Plugin = require('../plugin').Plugin

history_size = parseInt(process.env.npm_package_config_dynamicmode_history_size)
future_size = parseInt(process.env.npm_package_config_dynamicmode_future_size)
LAST_QUEUED_STICKER = "groovebasin.last-queued"

exports.Plugin = class DynamicMode extends Plugin
  constructor: ->
    super
    @previous_ids = {}
    @is_enabled = false
    @got_stickers = false
    # our cache of the LAST_QUEUED_STICKER
    @last_queued = {}

  restoreState: (state) =>
    @is_on = state.status.dynamic_mode ? false
    @random_ids = state.status.random_ids ? {}

  saveState: (state) =>
    state.status.dynamic_mode = @is_on
    state.status.dynamic_mode_enabled = @is_enabled
    state.status.random_ids = @random_ids

  setConf: (conf, conf_path) =>
    @is_enabled = true
    unless conf.sticker_file?
      @is_enabled = false
      @is_on = false
      @log.warn "sticker_file not set in #{conf_path}. Dynamic Mode disabled."

  setMpd: (@mpd) =>
    @mpd.on 'statusupdate', @checkDynamicMode
    @mpd.on 'playlistupdate', @checkDynamicMode
    @mpd.on 'libraryupdate', @updateStickers

  onSocketConnection: (socket) =>
    socket.on 'DynamicMode', (data) =>
      return unless @is_enabled
      args = JSON.parse data.toString()
      @log.debug "DynamicMode args:"
      @log.debug args
      did_anything = false
      for key, value of args
        switch key
          when "dynamic_mode"
            continue if @is_on is value
            did_anything = true
            @is_on = value
      if did_anything
        @checkDynamicMode()
        @onStatusChanged()

  checkDynamicMode: =>
    return unless @is_enabled
    return unless @mpd.library.artists.length
    return unless @got_stickers
    item_list = @mpd.playlist.item_list
    current_id = @mpd.status.current_item?.id
    current_index = -1
    all_ids = {}
    new_files = []
    for item, i in item_list
      if item.id is current_id
        current_index = i
      all_ids[item.id] = true
      new_files.push item.track.file unless @previous_ids[item.id]?
    # tag any newly queued tracks
    now = new Date()
    @mpd.setStickers new_files, LAST_QUEUED_STICKER, JSON.stringify(now), (err) =>
      if err then @log.warn "dynamic mode set stickers error:", err
    # anticipate the changes
    @last_queued[file] = now for file in new_files

    # if no track is playing, assume the first track is about to be
    if current_index is -1
      current_index = 0
    else
      # any tracks <= current track don't count as random anymore
      for i in [0..current_index]
        delete @random_ids[item_list[i].id]

    if @is_on
      delete_count = Math.max(current_index - history_size, 0)
      if history_size < 0
        delete_count = 0

      @mpd.removeIds (item_list[i].id for i in [0...delete_count])
      add_count = Math.max(future_size + 1 - (item_list.length - current_index), 0)
      @mpd.queueFiles @getRandomSongFiles(add_count), null, (err, items) =>
        throw err if err
        # track which ones are the automatic ones
        changed = false
        for item in items
          @random_ids[item.id] = true
          changed = true
        @onStatusChanged() if changed

    # scrub the random_ids (only if we're sure we're not still loading
    if item_list.length
      new_random_ids = {}
      for id of @random_ids
        if all_ids[id]
          new_random_ids[id] = true
      @random_ids = new_random_ids
    @previous_ids = all_ids
    @onStatusChanged()

  updateStickers: =>
    @mpd.findStickers '/', LAST_QUEUED_STICKER, (err, stickers) =>
      if err
        @log.error "dynamicmode findsticker error: #{err}"
        return
      for sticker of stickers
        [file, value] = sticker
        track = @mpd.library.track_table[file]
        @last_queued[file] = new Date(value)
      @got_stickers = true

  getRandomSongFiles: (count) =>
    return [] if count is 0
    never_queued = []
    sometimes_queued = []
    for file, track of @mpd.library.track_table
      console.log
      if @last_queued[file]?
        sometimes_queued.push track
      else
        never_queued.push track
    # backwards by time
    sometimes_queued.sort (a, b) =>
      @last_queued[b.file].getTime() - @last_queued[a.file].getTime()
    # distribution is a triangle for ever queued, and a rectangle for never queued
    #    ___
    #   /| |
    #  / | |
    # /__|_|
    max_weight = sometimes_queued.length
    triangle_area = Math.floor(max_weight * max_weight / 2)
    rectangle_area = max_weight * never_queued.length
    total_size = triangle_area + rectangle_area
    # decode indexes through the distribution shape
    files = []
    for i in [0...count]
      index = Math.random() * total_size
      if index < triangle_area
        # triangle
        track = sometimes_queued[Math.floor Math.sqrt index]
      else
        # rectangle
        track = never_queued[Math.floor((index - triangle_area) / max_weight)]
      files.push track.file
    files

