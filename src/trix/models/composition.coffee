#= require trix/models/document
#= require trix/models/attachment_manager
#= require trix/utilities/helpers

{countGraphemeClusters, defer} = Trix.Helpers

class Trix.Composition
  constructor: (@document = new Trix.Document, config) ->
    @document.delegate = this
    @currentAttributes = {}

    @attachments = new Trix.AttachmentManager this
    @attachments.delegate = config?.delegate
    @attachments.reset()

  # Snapshots

  createSnapshot: ->
    text: @getDocument()
    selectedRange: @getLocationRange()

  restoreSnapshot: ({document, selectedRange}) ->
    @document.replaceDocument(document)
    @setLocationRange(selectedRange)

  # Document delegate

  didEditDocument: (document) ->
    @delegate?.compositionDidChangeDocument?(this, @document)
    defer => @attachments.reset()

  # Responder protocol

  insertText: (text, {updatePosition} = updatePosition: true) ->
    range = @getLocationRange()
    @document.insertTextAtLocationRange(text, range)

    {index, position} = range.start
    position += text.getLength() if updatePosition
    @setLocationRange(new Trix.LocationRange {index, position})

  insertDocument: (document) ->
    range = @getLocationRange()
    @document.insertDocumentAtLocationRange(document, range)

    blockLength = document.blockList.blocks.length
    lastText = document.blockList.getBlockAtIndex(blockLength - 1).text

    index = range.index + blockLength
    position = lastText.getLength()
    @setLocationRange(new Trix.LocationRange {index, position})

  insertString: (string, options) ->
    text = Trix.Text.textForStringWithAttributes(string, @currentAttributes)
    @insertText(text, options)

  insertHTML: (html) ->
    document = Trix.Document.fromHTML(html)
    @insertDocument(document)

  replaceHTML: (html) ->
    @preserveSelectionEndPoint =>
      document = Trix.Document.fromHTML(html)
      @document.replaceDocument(document)

  insertFile: (file) ->
    if attachment = @attachments.create(file)
      text = Trix.Text.textForAttachmentWithAttributes(attachment, @currentAttributes)
      @insertText(text)

  deleteFromCurrentPosition: (distance = -1) ->
    range = @getLocationRange()

    if range.isCollapsed()
      {index, position} = range
      position += distance

      if distance < 0
        if position < 0
          index--
          position += @document.getTextAtIndex(index).getLength() + 1

        start = {index, position}
        end = range.start
      else
        if position > (textLength = @document.getTextAtIndex(index).getLength())
          index++
          position -= textLength + 1

        start = range.start
        end = {index, position}

      range = new Trix.LocationRange start, end

    @document.removeTextAtLocationRange(range)
    @setLocationRange(range.collapse())

  deleteBackward: ->
    distance = 1
    range = @getLocationRange()

    if range.isCollapsed() and range.position > 0
      while (leftPosition = range.position - distance - 1) >= 0
        string = @document.getTextAtIndex(range.index).getStringAtRange([leftPosition, range.position])
        if countGraphemeClusters(string) is 1 or countGraphemeClusters("n#{string}") is 1
          distance++
        else
          break

    @deleteFromCurrentPosition(distance * -1)

  deleteForward: ->
    distance = 1
    range = @getLocationRange()

    if range.isCollapsed()
      text = @document.getTextAtIndex(range.index)
      textLength = text.getLength()
      while (rightPosition = range.position + distance + 1) <= textLength
        string = text.getStringAtRange([range.position, rightPosition])
        if countGraphemeClusters(string) is 1
          distance++
        else
          break

    @deleteFromCurrentPosition(distance)

  deleteWordBackward: ->
    if @getLocationRange()
      @deleteBackward()
    else
      range = @getLocationRange()
      text = @getTextAtIndex(range.index)
      # TODO: delete across blocks
      stringBeforePosition = text.getStringAtRange([0, range.position])
      # TODO: \b is not unicode compatible
      positionBeforeLastWord = stringBeforePosition.search(/(\b\w+)\W*$/)
      @deleteFromCurrentPosition(positionBeforeLastWord - position)

  moveTextFromRange: (range) ->
    range = @getLocationRange()
    # TODO: move selection spanning blocks
    text = @getTextAtIndex(index)
    text.moveTextFromRangeToPosition(range, position)
    @requestPosition(position)

  getTextFromSelection: ->
    # TODO: get text(s) spanning blocks
    if range = @getLocationRange()
      if range[0].index is range[1].index
        text = @getTextAtIndex(range[0].index)
        text.getTextAtRange([range[0].position, range[1].position])

  # Attachment owner protocol

  getAttachments: ->
    @document.getAttachments()

  updateAttachment: (id, attributes) ->
    if attachment = @attachments.get(id)
      {text} = @document.getTextAndRangeOfAttachment(attachment)
      text.edit -> attachment.setAttributes(attributes)

  removeAttachment: (id) ->
    if attachment = @attachments.get(id)
      {text, range} = @document.getTextAndRangeOfAttachment(attachment)
      text.removeTextAtRange(range)

  # Current attributes

  hasCurrentAttribute: (attributeName) ->
    @currentAttributes[attributeName]?

  toggleCurrentAttribute: (attributeName) ->
    value = not @currentAttributes[attributeName]
    @setCurrentAttribute(attributeName, value)

  setCurrentAttribute: (attributeName, value) ->
    range = @getLocationRange()

    if value
      @document.addAttributeAtLocationRange(attributeName, value, range)
      @currentAttributes[attributeName] = value
    else
      @document.removeAttributeAtLocationRange(attributeName, range)
      delete @currentAttributes[attributeName]

    @notifyDelegateOfCurrentAttributesChange()

  updateCurrentAttributes: ->
    if range = @getLocationRange()
      @currentAttributes = @document.getCommonAttributesAtLocationRange(range)

    else if range = @getLocationRange()
      block = @document.getBlockAtIndex(range.index)
      @currentAttributes = block.getAttributes()

      attributes = block.text.getAttributesAtPosition(range.position)
      attributesLeft = block.text.getAttributesAtPosition(range.position - 1)

      for key, value of attributesLeft
        if value is attributes[key] or key in inheritableAttributes()
          @currentAttributes[key] = value

    @notifyDelegateOfCurrentAttributesChange()

  inheritableAttributes = ->
    for key, value of Trix.attributes when value.inheritable
      key

  notifyDelegateOfCurrentAttributesChange: ->
    @delegate?.compositionDidChangeCurrentAttributes?(this, @currentAttributes)

  # Selection freezing

  freezeSelection: ->
    @setCurrentAttribute("frozen", true)

  thawSelection: ->
    @setCurrentAttribute("frozen", false)

  hasFrozenSelection: ->
    @hasCurrentAttribute("frozen")

  # LocationRange

  getLocationRange: ->
    @selectionDelegate?.getLocationRange?()

  setLocationRange: (range) ->
    @selectionDelegate?.setLocationRange?(range)

  requestPositionAtPoint: (point) ->
    if range = @selectionDelegate?.getRangeOfCompositionAtPoint?(this, point)
      @requestSelectedRange(range)

  preserveSelectionEndPoint: (block) ->
    point = @selectionDelegate?.getPointAtEndOfCompositionSelection?(this)
    block()
    @requestPositionAtPoint(point) if point?

  expandSelectionForEditing: ->
    for key, value of Trix.attributes when value.parent
      if @hasCurrentAttribute(key)
        @expandLocationRangeAroundCommonAttribute(key)
        break

  expandLocationRangeAroundCommonAttribute: (attributeName) ->
    [left, right] = @documentView.getSelectedRange()
    originalLeft = left
    length = @text.getLength()

    left-- while left > 0 and @text.getCommonAttributesAtRange([left - 1, right])[attributeName]
    right++ while right < length and @text.getCommonAttributesAtRange([originalLeft, right + 1])[attributeName]

    @documentView.setSelectedRange([left, right])

  # Private

  getDocument: ->
    # TODO
    @document.copy?()
