RootView = require 'views/core/RootView'
template = require 'templates/play/campaign-view'
LevelSession = require 'models/LevelSession'
EarnedAchievement = require 'models/EarnedAchievement'
CocoCollection = require 'collections/CocoCollection'
Campaign = require 'models/Campaign'
AudioPlayer = require 'lib/AudioPlayer'
LevelSetupManager = require 'lib/LevelSetupManager'
ThangType = require 'models/ThangType'
MusicPlayer = require 'lib/surface/MusicPlayer'
storage = require 'core/storage'
AuthModal = require 'views/core/AuthModal'
SubscribeModal = require 'views/core/SubscribeModal'
LeaderboardModal = require 'views/play/modal/LeaderboardModal'
Level = require 'models/Level'
utils = require 'core/utils'
require 'vendor/three'
ParticleMan = require 'core/ParticleMan'

trackedHourOfCode = false

class LevelSessionsCollection extends CocoCollection
  url: ''
  model: LevelSession

  constructor: (model) ->
    super()
    @url = "/db/user/#{me.id}/level.sessions?project=state.complete,levelID"

module.exports = class CampaignView extends RootView
  id: 'campaign-view'
  template: template

  subscriptions:
    'subscribe-modal:subscribed': 'onSubscribed'

  events:
    'click .map-background': 'onClickMap'
    'click .level a': 'onClickLevel'
    'dblclick .level a': 'onDoubleClickLevel'
    'click .level-info-container .start-level': 'onClickStartLevel'
    'click .level-info-container .view-solutions': 'onClickViewSolutions'
    'click #volume-button': 'onToggleVolume'

  constructor: (options, @terrain='dungeon') ->
    super options
    options ?= {}

    @campaign = new Campaign({_id:@terrain})
    @campaign = @supermodel.loadModel(@campaign, 'campaign').model

    @editorMode = options.editorMode
    @levelStatusMap = {}
    @levelPlayCountMap = {}
    @sessions = @supermodel.loadCollection(new LevelSessionsCollection(), 'your_sessions', null, 0).model

    # Temporary attempt to make sure all earned rewards are accounted for. Figure out a better solution...
    @earnedAchievements = new CocoCollection([], {url: '/db/earned_achievement', model:EarnedAchievement, project: ['earnedRewards']})
    @listenToOnce @earnedAchievements, 'sync', ->
      earned = me.get('earned')
      for m in @earnedAchievements.models
        continue unless loadedEarned = m.get('earnedRewards')
        for group in ['heroes', 'levels', 'items']
          continue unless loadedEarned[group]
          for reward in loadedEarned[group]
            if reward not in earned[group]
              console.warn 'Filling in a gap for reward', group, reward
              earned[group].push(reward)

    @supermodel.loadCollection(@earnedAchievements, 'achievements')

    @listenToOnce @sessions, 'sync', @onSessionsLoaded
    @listenToOnce @campaign, 'sync', @getLevelPlayCounts
    $(window).on 'resize', @onWindowResize
    @probablyCachedMusic = storage.load("loaded-menu-music")
    musicDelay = if @probablyCachedMusic then 1000 else 10000
    @playMusicTimeout = _.delay (=> @playMusic() unless @destroyed), musicDelay
    @hadEverChosenHero = me.get('heroConfig')?.thangType
    @listenTo me, 'change:purchased', -> @renderSelectors('#gems-count')
    @listenTo me, 'change:spent', -> @renderSelectors('#gems-count')
    @listenTo me, 'change:heroConfig', -> @updateHero()
    window.tracker?.trackEvent 'Loaded World Map', category: 'World Map', ['Google Analytics']

    # If it's a new player who didn't appear to come from Hour of Code, we register her here without setting the hourOfCode property.
    elapsed = (new Date() - new Date(me.get('dateCreated')))
    if not trackedHourOfCode and not me.get('hourOfCode') and elapsed < 5 * 60 * 1000
      $('body').append($('<img src="http://code.org/api/hour/begin_codecombat.png" style="visibility: hidden;">'))
      trackedHourOfCode = true

    @requiresSubscription = not me.isPremium()

  destroy: ->
    @setupManager?.destroy()
    @$el.find('.ui-draggable').off().draggable 'destroy'
    $(window).off 'resize', @onWindowResize
    if ambientSound = @ambientSound
      # Doesn't seem to work; stops immediately.
      createjs.Tween.get(ambientSound).to({volume: 0.0}, 1500).call -> ambientSound.stop()
    @musicPlayer?.destroy()
    clearTimeout @playMusicTimeout
    @particleMan?.destroy()
    super()

  getLevelPlayCounts: ->
    return unless me.isAdmin()
    return  # TODO: get rid of all this? It's redundant with new campaign editor analytics, unless we want to show player counts on leaderboards buttons.
    success = (levelPlayCounts) =>
      return if @destroyed
      for level in levelPlayCounts
        @levelPlayCountMap[level._id] = playtime: level.playtime, sessions: level.sessions
      @render() if @fullyRendered

    levelSlugs = (level.slug for levelID, level of @campaign.get 'levels')
    levelPlayCountsRequest = @supermodel.addRequestResource 'play_counts', {
      url: '/db/level/-/play_counts'
      data: {ids: levelSlugs}
      method: 'POST'
      success: success
    }, 0
    levelPlayCountsRequest.load()

  onLoaded: ->
    return if @fullyRendered
    @fullyRendered = true
    @render()
    @preloadTopHeroes() unless me.get('heroConfig')?.thangType
    @$el.find('#campaign-status').delay(4000).animate({top: "-=58"}, 1000) unless @terrain is 'dungeon'

  setCampaign: (@campaign) ->
    @render()

  onSubscribed: ->
    @requiresSubscription = false
    @render()

  getRenderData: (context={}) ->
    context = super(context)
    context.campaign = @campaign
    context.levels = _.values($.extend true, {}, @campaign.get('levels'))
    context.levelsCompleted = context.levelsTotal = 0
    for level in context.levels
      level.position ?= { x: 10, y: 10 }
      level.locked = not me.ownsLevel level.original
      level.locked = false if @levelStatusMap[level.slug] in ['started', 'complete']
      level.locked = false if @editorMode
      level.locked = false if @campaign.get('name') is 'Auditions'
      level.disabled = true if level.adminOnly and @levelStatusMap[level.slug] not in ['started', 'complete']
      level.color = 'rgb(255, 80, 60)'
      if level.requiresSubscription
        level.color = 'rgb(80, 130, 200)'
      if unlocksHero = _.find(level.rewards, 'hero')?.hero
        level.unlocksHero = unlocksHero
      if level.unlocksHero
        level.purchasedHero = level.unlocksHero in (me.get('purchased')?.heroes or [])
      level.hidden = level.locked
      unless level.disabled
        ++context.levelsTotal
        ++context.levelsCompleted if @levelStatusMap[level.slug] is 'complete'

    @determineNextLevel context.levels if @sessions.loaded
    # put lower levels in last, so in the world map they layer over one another properly.
    context.levels = (_.sortBy context.levels, (l) -> l.position.y).reverse()
    @campaign.renderedLevels = context.levels

    context.levelStatusMap = @levelStatusMap
    context.levelPlayCountMap = @levelPlayCountMap
    context.isIPadApp = application.isIPadApp
    context.mapType = _.string.slugify @terrain
    context.requiresSubscription = @requiresSubscription
    context.editorMode = @editorMode
    context.adjacentCampaigns = _.filter _.values(_.cloneDeep(@campaign.get('adjacentCampaigns') or {})), (ac) =>
      return false if ac.showIfUnlocked and (ac.showIfUnlocked not in me.levels()) and not @editorMode
      ac.name = utils.i18n ac, 'name'
      styles = []
      styles.push "color: #{ac.color}" if ac.color
      styles.push "transform: rotate(#{ac.rotation}deg)" if ac.rotation
      ac.position ?= { x: 10, y: 10 }
      styles.push "left: #{ac.position.x}%"
      styles.push "top: #{ac.position.y}%"
      ac.style = styles.join('; ')
      return true
    context.marked = marked
    context.i18n = utils.i18n
    context

  afterRender: ->
    super()
    @onWindowResize()
    unless application.isIPadApp
      _.defer => @$el?.find('.game-controls .btn').addClass('has-tooltip').tooltip()  # Have to defer or i18n doesn't take effect.
      view = @
      @$el.find('.level, .campaign-switch').addClass('has-tooltip').tooltip().each ->
        return unless me.isAdmin() and view.editorMode
        $(@).draggable().on 'dragstop', ->
          bg = $('.map-background')
          x = ($(@).offset().left - bg.offset().left + $(@).outerWidth() / 2) / bg.width()
          y = 1 - ($(@).offset().top - bg.offset().top + $(@).outerHeight() / 2) / bg.height()
          e = { position: { x: (100 * x), y: (100 * y) }, levelOriginal: $(@).data('level-original'), campaignID: $(@).data('campaign-id') }
          view.trigger 'level-moved', e if e.levelOriginal
          view.trigger 'adjacent-campaign-moved', e if e.campaignID
    @updateVolume()
    @updateHero()
    unless window.currentModal or not @fullyRendered
      @highlightElement '.level.next', delay: 500, duration: 60000, rotation: 0, sides: ['top']
      if @editorMode
        for level in @campaign.renderedLevels
          for nextLevelOriginal in level.nextLevels ? []
            if nextLevel = _.find(@campaign.renderedLevels, original: nextLevelOriginal)
              @createLine level.position, nextLevel.position
      @showLeaderboard @options.justBeatLevel?.get('slug') if @options.showLeaderboard# or true  # Testing
    @applyCampaignStyles()
    @testParticles()

  afterInsert: ->
    super()
    return unless @getQueryVariable 'signup'
    return if me.get('email')
    @endHighlight()
    authModal = new AuthModal supermodel: @supermodel
    authModal.mode = 'signup'
    @openModalView authModal

  showLeaderboard: (levelSlug) ->
    #levelSlug ?= 'siege-of-stonehold'  # Testing
    leaderboardModal = new LeaderboardModal supermodel: @supermodel, levelSlug: levelSlug
    @openModalView leaderboardModal

  determineNextLevel: (levels) ->
    foundNext = false
    for level in levels
      level.nextLevels = (reward.level for reward in level.rewards when reward.level)
      unless foundNext
        for nextLevelOriginal in level.nextLevels
          nextLevel = _.find levels, original: nextLevelOriginal
          if nextLevel and not nextLevel.locked and @levelStatusMap[nextLevel.slug] isnt 'complete' and (me.isPremium() or not nextLevel.requiresSubscription)
            nextLevel.next = true
            foundNext = true
            break
    if not foundNext and levels[0] and not levels[0].locked and @levelStatusMap[levels[0].slug] isnt 'complete'
      levels[0].next = true

  createLine: (o1, o2) ->
    p1 = x: o1.x, y: 0.66 * o1.y + 0.5
    p2 = x: o2.x, y: 0.66 * o2.y + 0.5
    length = Math.sqrt((p1.x - p2.x) * (p1.x - p2.x) + (p1.y - p2.y) * (p1.y - p2.y))
    angle = Math.atan2(p1.y - p2.y, p2.x - p1.x) * 180 / Math.PI
    transform = "rotate(#{angle}deg)"
    line = $('<div>').appendTo('.map').addClass('next-level-line').css(transform: transform, width: length + '%', left: o1.x + '%', bottom: (o1.y + 0.5) + '%')
    line.append($('<div class="line">')).append($('<div class="point">'))

  applyCampaignStyles: ->
    return unless @campaign.loaded
    if (backgrounds = @campaign.get 'backgroundImage') and backgrounds.length
      backgrounds = _.sortBy backgrounds, 'width'
      backgrounds.reverse()
      rules = []
      for background, i in backgrounds
        rule = "#campaign-view .map-background { background-image: url(/file/#{background.image}); }"
        rule = "@media screen and (max-width: #{background.width}px) { #{rule} }" if i
        rules.push rule
      utils.injectCSS rules.join('\n')
    if backgroundColor = @campaign.get 'backgroundColor'
      backgroundColorTransparent = @campaign.get 'backgroundColorTransparent'
      @$el.css 'background-color', backgroundColor
      for pos in ['top', 'right', 'bottom', 'left']
        @$el.find(".#{pos}-gradient").css 'background-image', "linear-gradient(to #{pos}, #{backgroundColorTransparent} 0%, #{backgroundColor} 100%)"
    @playAmbientSound()

  testParticles: ->
    return unless @campaign.loaded and me.getForeshadowsLevels()
    @particleMan ?= new ParticleMan()
    @particleMan.removeEmitters()
    @particleMan.attach @$el.find('.map')
    for level in @campaign.renderedLevels ? {} when level.hidden
      particleKey = ['level', @terrain]
      particleKey.push level.type if level.type and level.type isnt 'hero'
      particleKey.push 'premium' if level.requiresSubscription
      particleKey.push 'gate' if level.slug in ['kithgard-gates', 'siege-of-stonehold', 'clash-of-clones']
      particleKey.push 'hero' if level.unlocksHero and not level.unlockedHero
      continue if particleKey.length is 2  # Don't show basic levels
      @particleMan.addEmitter level.position.x / 100, level.position.y / 100, particleKey.join('-')

  onSessionsLoaded: (e) ->
    return if @editorMode
    for session in @sessions.models
      @levelStatusMap[session.get('levelID')] = if session.get('state')?.complete then 'complete' else 'started'
    @render()

  preloadLevel: (levelSlug) ->
    levelURL = "/db/level/#{levelSlug}"
    level = new Level().setURL levelURL
    level = @supermodel.loadModel(level, 'level', null, 0).model
    sessionURL = "/db/level/#{levelSlug}/session"
    @preloadedSession = new LevelSession().setURL sessionURL
    @preloadedSession.levelSlug = levelSlug
    @preloadedSession.fetch()
    @listenToOnce @preloadedSession, 'sync', @onSessionPreloaded

  onSessionPreloaded: (session) ->
    levelElement = @$el.find('.level-info-container:visible')
    return unless session.levelSlug is levelElement.data 'level-slug'
    return unless difficulty = session.get('state')?.difficulty
    badge = $("<span class='badge'>#{difficulty}</span>")
    levelElement.find('.start-level .badge').remove()
    levelElement.find('.start-level').append badge

  onClickMap: (e) ->
    @$levelInfo?.hide()

  onClickLevel: (e) ->
    e.preventDefault()
    e.stopPropagation()
    @$levelInfo?.hide()
    levelElement = $(e.target).parents('.level')
    levelSlug = levelElement.data('level-slug')
    levelOriginal = levelElement.data('level-original')
    if @editorMode
      return @trigger 'level-clicked', levelOriginal
    @$levelInfo = @$el.find(".level-info-container[data-level-slug=#{levelSlug}]").show()
    @adjustLevelInfoPosition e
    @endHighlight()
    @preloadLevel levelSlug

  onDoubleClickLevel: (e) ->
    return unless @editorMode
    levelElement = $(e.target).parents('.level')
    levelOriginal = levelElement.data('level-original')
    @trigger 'level-double-clicked', levelOriginal

  onClickStartLevel: (e) ->
    levelElement = $(e.target).parents('.level-info-container')
    levelSlug = levelElement.data('level-slug')
    levelOriginal = levelElement.data('level-original')
    level = _.find _.values(@campaign.get('levels')), slug: levelSlug

    if level.requiresSubscription and @requiresSubscription and not @levelStatusMap[level.slug] and not level.adventurer
      @openModalView new SubscribeModal()
      window.tracker?.trackEvent 'Show subscription modal', category: 'Subscription', label: 'map level clicked', level: levelSlug
    else
      @startLevel levelElement
      window.tracker?.trackEvent 'Clicked Start Level', category: 'World Map', levelID: levelSlug, ['Google Analytics']

  startLevel: (levelElement) ->
    @setupManager?.destroy()
    levelSlug = levelElement.data 'level-slug'
    session = @preloadedSession if @preloadedSession?.loaded and @preloadedSession.levelSlug is levelSlug
    @setupManager = new LevelSetupManager supermodel: @supermodel, levelID: levelSlug, levelPath: levelElement.data('level-path'), levelName: levelElement.data('level-name'), hadEverChosenHero: @hadEverChosenHero, parent: @, session: session
    @setupManager.open()
    @$levelInfo?.hide()

  onClickViewSolutions: (e) ->
    levelElement = $(e.target).parents('.level-info-container')
    levelSlug = levelElement.data('level-slug')
    @showLeaderboard levelSlug

  adjustLevelInfoPosition: (e) ->
    return unless @$levelInfo
    @$map ?= @$el.find('.map')
    mapOffset = @$map.offset()
    mapX = e.pageX - mapOffset.left
    mapY = e.pageY - mapOffset.top
    margin = 20
    width = @$levelInfo.outerWidth()
    @$levelInfo.css('left', Math.min(Math.max(margin, mapX - width / 2), @$map.width() - width - margin))
    height = @$levelInfo.outerHeight()
    top = mapY - @$levelInfo.outerHeight() - 60
    if top < 100
      top = mapY + 60
    @$levelInfo.css('top', top)

  onWindowResize: (e) =>
    mapHeight = iPadHeight = 1536
    mapWidth = {dungeon: 2350, forest: 2500, auditions: 2500, desert: 2350, mountain: 2422}[@terrain] or 2350
    aspectRatio = mapWidth / mapHeight
    pageWidth = @$el.width()
    pageHeight = @$el.height()
    widthRatio = pageWidth / mapWidth
    heightRatio = pageHeight / mapHeight
    # Make sure we can see the whole map, fading to background in one dimension.
    if heightRatio <= widthRatio
      # Left and right margin
      resultingHeight = pageHeight
      resultingWidth = resultingHeight * aspectRatio
    else
      # Top and bottom margin
      resultingWidth = pageWidth
      resultingHeight = resultingWidth / aspectRatio
    resultingMarginX = (pageWidth - resultingWidth) / 2
    resultingMarginY = (pageHeight - resultingHeight) / 2
    @$el.find('.map').css(width: resultingWidth, height: resultingHeight, 'margin-left': resultingMarginX, 'margin-top': resultingMarginY)
    @testParticles() if @particleMan

  playAmbientSound: ->
    return if @ambientSound
    return unless file = @campaign?.get('ambientSound')?[AudioPlayer.ext.substr 1]
    src = "/file/#{file}"
    unless AudioPlayer.getStatus(src)?.loaded
      AudioPlayer.preloadSound src
      Backbone.Mediator.subscribeOnce 'audio-player:loaded', @playAmbientSound, @
      return
    @ambientSound = createjs.Sound.play src, loop: -1, volume: 0.1
    createjs.Tween.get(@ambientSound).to({volume: 0.5}, 1000)

  playMusic: ->
    @musicPlayer = new MusicPlayer()
    musicFile = '/music/music-menu'
    Backbone.Mediator.publish 'music-player:play-music', play: true, file: musicFile
    storage.save("loaded-menu-music", true) unless @probablyCachedMusic

  preloadTopHeroes: ->
    for heroID in ['captain', 'knight']
      url = "/db/thang.type/#{ThangType.heroes[heroID]}/version"
      continue if @supermodel.getModel url
      fullHero = new ThangType()
      fullHero.setURL url
      @supermodel.loadModel fullHero, 'thang'

  updateVolume: (volume) ->
    volume ?= me.get('volume') ? 1.0
    classes = ['vol-off', 'vol-down', 'vol-up']
    button = $('#volume-button', @$el)
    button.toggleClass 'vol-off', volume <= 0.0
    button.toggleClass 'vol-down', 0.0 < volume < 1.0
    button.toggleClass 'vol-up', volume >= 1.0
    createjs.Sound.setVolume(if volume is 1 then 0.6 else volume)  # Quieter for now until individual sound FX controls work again.
    if volume isnt me.get 'volume'
      me.set 'volume', volume
      me.patch()

  onToggleVolume: (e) ->
    button = $(e.target).closest('#volume-button')
    classes = ['vol-off', 'vol-down', 'vol-up']
    volumes = [0, 0.4, 1.0]
    for oldClass, i in classes
      if button.hasClass oldClass
        newI = (i + 1) % classes.length
        break
      else if i is classes.length - 1  # no oldClass
        newI = 2
    @updateVolume volumes[newI]

  updateHero: ->
    return unless hero = me.get('heroConfig')?.thangType
    for slug, original of ThangType.heroes when original is hero
      @$el.find('.player-hero-icon').removeClass().addClass('player-hero-icon ' + slug)
      return
    console.error "CampaignView hero update couldn't find hero slug for original:", hero
