# = require ./tabs/file-tab.coffee
# = require ./tabs/url-tab.coffee
# = require ./tabs/camera-tab.coffee
# = require ./tabs/remote-tab.coffee
# = require ./tabs/base-preview-tab.coffee
# = require ./tabs/preview-tab.coffee
# = require ./tabs/preview-tab-multiple.coffee

{
  utils,
  locale: {t},
  templates: {tpl},
  files,
  widget: {tabs},
  settings: s,
  jQuery: $
} = uploadcare

uploadcare.namespace '', (ns) ->

  lockScroll = (el, toTop) ->
    top = el.scrollTop()
    left = el.scrollLeft()
    if toTop
      el.scrollTop(0).scrollLeft(0)
    ->
      el.scrollTop(top).scrollLeft(left)

  $(window).on 'keydown', (e) =>
    if ns.isDialogOpened()
      if e.which == 27  # Escape
        e.stopImmediatePropagation()
        # close only topmost dialog
        currentDialogPr?.reject()

  currentDialogPr = null
  openedClass = 'uploadcare--page'

  ns.isDialogOpened = ->
    currentDialogPr != null

  ns.closeDialog = ->
    while currentDialogPr
      currentDialogPr.reject()

  ns.openDialog = (files, tab, settings) ->
    ns.closeDialog()

    dialog = $(tpl('dialog')).appendTo('body')
    dialog.append($(tpl('icons')))
    dialogPr = ns.openPanel(dialog.find('.uploadcare--dialog__placeholder'),
                            files, tab, settings)
    dialog.addClass('uploadcare--dialog_active')
    dialogPr.dialogElement = dialog

    if settings.multiple
      dialog.addClass('uploadcare--dialog_multiple')

    cancelLock = lockScroll($(window), dialog.css('position') is 'absolute')
    $('html, body').addClass(openedClass)

    dialog.find('.uploadcare--dialog__close')
      .on('click', dialogPr.reject)

    dialog.on 'dblclick', (e) ->
      # handler can be called after element detached (close button)
      if not $.contains(document.documentElement, e.target)
        return

      showStoppers = '.uploadcare--dialog__content, a'
      if $(e.target).is(showStoppers) or $(e.target).parents(showStoppers).length
        return

      dialogPr.reject()

    return currentDialogPr = dialogPr.always ->
      $('html, body').removeClass(openedClass)
      currentDialogPr = null
      dialog.remove()
      cancelLock()


  ns.openPreviewDialog = (file, settings) ->
    # hide current opened dialog and open new one
    oldDialogPr = currentDialogPr
    currentDialogPr = null

    settings = $.extend({}, settings, {
      multiple: false
      tabs: ''
    })
    dialog = uploadcare.openDialog(file, 'preview', settings)
    oldDialogPr.dialogElement.addClass('uploadcare--dialog_inactive')

    dialog.always ->
      currentDialogPr = oldDialogPr
      # still opened
      $('html, body').addClass(openedClass)
      oldDialogPr.dialogElement.removeClass('uploadcare--dialog_inactive')
    dialog.onTabVisibility (tab, shown) =>
      if tab == 'preview' and not shown
        dialog.reject()

    dialog


  # files - null, or File object, or array of File objects, or FileGroup object
  # result - File objects or FileGroup object (depends on settings.multiple)
  ns.openPanel = (placeholder, files, tab, settings) ->
    if $.isPlainObject(tab)
      settings = tab
      tab = null

    if not files
      files = []
    else if utils.isFileGroup(files)
      files = files.files()
    else if not $.isArray(files)
      files = [files]

    settings = s.build(settings)
    panel = new Panel(settings, placeholder, files, tab).publicPromise()

    filter = (files) ->
      if settings.multiple
        uploadcare.FileGroup(files, settings)
      else
        files[0]

    utils.then(panel, filter, filter).promise(panel)


  registeredTabs = {}

  ns.registerTab = (tabName, constructor) ->
    registeredTabs[tabName] = constructor

  ns.registerTab('file', tabs.FileTab)
  ns.registerTab('url', tabs.UrlTab)
  ns.registerTab('camera', tabs.CameraTab)
  ns.registerTab('facebook', tabs.RemoteTab)
  ns.registerTab('dropbox', tabs.RemoteTab)
  ns.registerTab('gdrive', tabs.RemoteTab)
  ns.registerTab('gphotos', tabs.RemoteTab)
  ns.registerTab('instagram', tabs.RemoteTab)
  ns.registerTab('flickr', tabs.RemoteTab)
  ns.registerTab('vk', tabs.RemoteTab)
  ns.registerTab('evernote', tabs.RemoteTab)
  ns.registerTab('box', tabs.RemoteTab)
  ns.registerTab('skydrive', tabs.RemoteTab)
  ns.registerTab('huddle', tabs.RemoteTab)
  ns.registerTab 'empty-pubkey', (tabPanel, _1, _2, settings) ->
    tabPanel.append(settings._emptyKeyText)
  ns.registerTab 'preview', (tabPanel, tabButton, dialogApi, settings, name) ->
    tabCls = if settings.multiple
        tabs.PreviewTabMultiple
      else
        tabs.PreviewTab
    new tabCls(tabPanel, tabButton, dialogApi, settings, name)

  class Panel
    constructor: (@settings, placeholder, files, tab) ->
      @dfd = $.Deferred()
      @dfd.always(@__closePanel)

      sel = '.uploadcare--dialog__panel'
      @content = $(tpl('dialog__panel'))
      @panel = @content.find(sel).add(@content.filter(sel))
      @placeholder = $(placeholder)
      @placeholder.replaceWith(@content)

      @panel.find('.uploadcare--menu__toggle')
        .on 'click', =>
          @panel.find('.uploadcare--menu').toggleClass('uploadcare--menu_opened')

      # files collection
      @files = new utils.CollectionOfPromises(files)
      @files.onRemove.add =>
        if @files.length() == 0
          @hideTab('preview')

      @__autoCrop(@files)

      @tabs = {}
      @__prepareFooter()

      @onTabVisibility = $.Callbacks().add (tab, show) =>
        @panel.find(".uploadcare--menu__item_#{tab}")
              .toggleClass("uploadcare--menu__item_hidden", not show)

      if @settings.publicKey
        @__prepareTabs(tab)
      else
        @__welcome()

    publicPromise: ->
      if not @promise
        @promise = @dfd.promise(
          reject: @__reject
          resolve: @__resolve
          fileColl: @files
          addFiles: @addFiles
          switchTab: @switchTab
          hideTab: @hideTab
          showTab: @showTab
          isTabVisible: @isTabVisible
          openMenu: @openMenu
          onTabVisibility: utils.publicCallbacks(@onTabVisibility)
        )
      @promise

    # (fileType, data) or ([fileObject, fileObject])
    addFiles: (files, data) =>
      if data
        # 'files' is actually file type
        files = ns.filesFrom(files, data, @settings)

      if not @settings.multiple
        @files.clear()

      for file in files
        if @settings.multipleMaxStrict and @settings.multipleMax != 0
          if @files.length() >= @settings.multipleMax
            file.cancel()
            continue
        @files.add(file)

      if @settings.previewStep
        @showTab('preview')
        if not @settings.multiple
          @switchTab('preview')
      else
        @__resolve()

    __autoCrop: (files) ->
      if not @settings.crop or not @settings.multiple
        return

      for crop in @settings.crop
        # if even one of crop option sets allow free crop,
        # we don't need to crop automatically
        if not crop.preferedSize
          return

      files.onAnyDone (file, fileInfo) =>
        # .cdnUrlModifiers came from already cropped files
        # .crop came from autocrop even if autocrop do not set cdnUrlModifiers
        if not fileInfo.isImage or fileInfo.cdnUrlModifiers or fileInfo.crop
          return

        info = fileInfo.originalImageInfo
        size = uploadcare.utils.fitSize(
          @settings.crop[0].preferedSize,
          [info.width, info.height],
          true
        )

        newFile = utils.applyCropSelectionToFile(
          file, @settings.crop[0], [info.width, info.height], {
            width: size[0]
            height: size[1]
            left: Math.round((info.width - size[0]) / 2)
            top: Math.round((info.height - size[1]) / 2)
          }
        )
        files.replace(file, newFile)

    __resolve: =>
      @dfd.resolve(@files.get())

    __reject: =>
      @dfd.reject(@files.get())

    __prepareTabs: (tab) ->
      @addTab('preview')
      for tabName in @settings.tabs
        @addTab(tabName)

      if @files.length()
        @showTab('preview')
        @switchTab('preview')
      else
        @hideTab('preview')
        @switchTab(tab || @__firstVisibleTab())

      if @settings.tabs.length == 0
        @panel.find('.uploadcare--dialog__menu').addClass('uploadcare--dialog__menu_hidden')

    __prepareFooter: ->
      @footer = @panel.find('.uploadcare--dialog__footer')
      notDisabled = ':not([aria-disabled=true])'
      @footer.on 'click', '.uploadcare--dialog__show-files' + notDisabled, =>
        @switchTab('preview')
      @footer.on('click', '.uploadcare--dialog__done' + notDisabled, @__resolve)

      @__updateFooter()
      @files.onAdd.add(@__updateFooter)
      @files.onRemove.add(@__updateFooter)

    __updateFooter: =>
        files = @files.length()
        tooManyFiles = @settings.multipleMax != 0 and files > @settings.multipleMax
        tooFewFiles = files < @settings.multipleMin

        @footer.find('.uploadcare--dialog__done')
          .attr('aria-disabled', tooManyFiles or tooFewFiles)

        @footer.find('.uploadcare--dialog__show-files')
          .attr('aria-disabled', files is 0)

        footer = if tooManyFiles
          t('dialog.tabs.preview.multiple.tooManyFiles')
            .replace('%max%', @settings.multipleMax)
        else if files and tooFewFiles
          t('dialog.tabs.preview.multiple.tooFewFiles')
            .replace('%min%', @settings.multipleMin)
        else
          t('dialog.tabs.preview.multiple.title')

        @footer.find('.uploadcare--dialog__message')
          .toggleClass('uploadcare--error', tooManyFiles)
          .text(footer.replace('%files%', t('file', files)))

        @footer.find('.uploadcare--dialog__file-counter')
          .toggleClass('uploadcare--error', tooManyFiles)
          .text(if files then "(#{files})" else "")

    __closePanel: =>
      @panel.replaceWith(@placeholder)
      @content.remove()

    addTab: (name) ->
      if name of @tabs
        return

      TabCls = registeredTabs[name]

      if not TabCls
        throw new Error("No such tab: #{name}")

      tabPanel = $('<div>')
        .addClass("uploadcare--panel")
        .addClass("uploadcare--panel_#{name}")
        .insertBefore(@footer)

      if name == 'preview'
        tabIcon = $('<div class="uploadcare--dialog__icon">')
      else
        tabIcon = $("<svg width='32' height='32'><use xlink:href='#uploadcare--icon-#{name}'/></svg>")
          .attr('role', 'presentation')
          .addClass('uploadcare--icon')
          .addClass('uploadcare--menu__icon')

      tabButton = $('<div>', {role: 'button', tabindex: "0"})
        .addClass('uploadcare--menu__item')
        .addClass("uploadcare--menu__item_#{name}")
        .attr('title', t("dialog.tabs.names.#{name}"))
        .append(tabIcon)
        .appendTo(@panel.find(".uploadcare--menu__items"))
        .on 'click', =>
          if name is @currentTab
            @panel.find('.uploadcare--dialog__menu').removeClass('uploadcare--menu_opened')
          else
              @switchTab(name)

      @tabs[name] = new TabCls(tabPanel, tabButton, @publicPromise(), @settings, name)

    switchTab: (tab) =>
      if not tab
        return
      @currentTab = tab

      @panel.find('.uploadcare--dialog__menu')
        .removeClass('uploadcare--menu_opened')
        .attr('data-current', tab)

      @panel.find(".uploadcare--menu__item")
            .removeClass("uploadcare--menu__item_current")
            .filter(".uploadcare--menu__item_#{tab}")
            .addClass("uploadcare--menu__item_current")

      className = "uploadcare--panel"
      @panel.find(".#{className}")
            .removeClass("#{className}_current")
            .filter(".#{className}_#{tab}")
            .addClass("#{className}_current")

      @dfd.notify(tab)

    showTab: (tab) =>
      @onTabVisibility.fire(tab, true)

    hideTab: (tab) =>
      @onTabVisibility.fire(tab, false)
      if @currentTab == tab
        @switchTab(@__firstVisibleTab())

    isTabVisible: (tab) =>
      not @panel.find(".uploadcare--menu__item_#{tab}")\
            .is(".uploadcare--menu__item_hidden")

    openMenu: =>
      @panel.find('.uploadcare--dialog__menu').addClass('uploadcare--menu_opened')

    __firstVisibleTab: ->
      for tab in @settings.tabs
        if @isTabVisible(tab)
          return tab

    __welcome: ->
      @addTab('empty-pubkey')
      @switchTab('empty-pubkey')
      for tabName in @settings.tabs
        @__addFakeTab(tabName)
      null

    __addFakeTab: (name) ->
      $('<div>', {role: 'button', tabindex: "0"})
        .addClass('uploadcare--menu__item')
        .addClass("uploadcare--menu__item_#{name}")
        .attr('aria-disabled', true)
        .attr('title', t("dialog.tabs.names.#{name}"))
        .appendTo(@panel.find(".uploadcare--menu__items"))
