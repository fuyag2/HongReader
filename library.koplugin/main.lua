local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local FFIUtil = require("ffi/util")
local FileManagerUtil = require("apps/filemanager/filemanagerutil")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local ReadCollection = require("readcollection")
local ReadHistory = require("readhistory")
local Size = require("ui/size")
local BookList = require("ui/widget/booklist")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")

local Screen = Device.screen

local SUPPORTED_EXTENSIONS = {
    azw = true,
    azw3 = true,
    cb7 = true,
    cbr = true,
    cbz = true,
    djvu = true,
    docx = true,
    epub = true,
    fb2 = true,
    html = true,
    mobi = true,
    odt = true,
    pdf = true,
    rtf = true,
    txt = true,
    xhtml = true,
}

local MAX_SCAN_DEPTH = 8
local MAX_SCANNED_BOOKS = 250
local MAX_VISIBLE_BOOKS = 5

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function pointIsInside(pos, rect)
    return pos and rect
        and pos.x >= rect.x and pos.x <= rect.x + rect.w
        and pos.y >= rect.y and pos.y <= rect.y + rect.h
end

-- CRE always draws a thin progress gauge along the bottom edge of its
-- alternative status header.  Keep the useful header text, but cover that
-- gauge after the page has been painted.
local HeaderProgressMask = Widget:extend{}

function HeaderProgressMask:paintTo(bb, x, y)
    local document = self.ui and self.ui.document
    if not document or not document.getHeaderHeight
            or not document.configurable
            or document.configurable.status_line ~= 0
            or not self.view or self.view.view_mode ~= "page" then
        return
    end

    local header_height = document:getHeaderHeight()
    if not header_height or header_height <= 0 then return end

    -- CRE reserves four pixels below the text for its gauge. Cover only the
    -- three gauge pixels so descenders in a large status font remain intact.
    -- CRE's HEADER_MARGIN and gauge geometry are raw framebuffer pixels, so
    -- these must not be DPI-scaled (which was what clipped the text on Kindle).
    local mask_above = 3
    local mask_below = 2
    bb:paintRect(
        x,
        y + math.max(0, header_height - mask_above),
        Screen:getWidth(),
        mask_above + mask_below,
        Blitbuffer.COLOR_WHITE
    )
end

local function cleanBookName(filename)
    local extension = filename:match("%.([^%.]+)$") or ""
    local name = filename:gsub("%.[^%.]+$", ""):gsub("_", " ")
    local lower_name = name:lower()

    -- Keep download-source clutter out of the UI without renaming the file.
    for _, marker in ipairs({ " (z-library", " (z-lib", " (1lib" }) do
        local marker_start = lower_name:find(marker, 1, true)
        if marker_start then
            name = name:sub(1, marker_start - 1)
            break
        end
    end

    local title, author = name:match("^(.-)%s+%(([^()]*)%)$")
    if not title then
        title, author = name:match("^(.-)%s+%-%s+(.+)$")
    end

    return {
        title = title or name,
        author = author or _("Unknown author"),
        format = extension:upper(),
    }
end

local function getFolderName(path)
    return path:match("([^/]+)/?$") or path
end

local PageSlider = InputContainer:extend{}

function PageSlider:init()
    self.screen_width = Screen:getWidth()
    self.screen_height = Screen:getHeight()
    self.page_count = math.max(1, self.ui.document:getPageCount())
    self.original_page = clamp(self.ui:getCurrentPage(), 1, self.page_count)
    self.target_page = self.original_page
    self.covers_fullscreen = false

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    if Device:isTouchDevice() then
        local full_screen = Geom:new{
            x = 0,
            y = 0,
            w = self.screen_width,
            h = self.screen_height,
        }
        self.ges_events = {
            TapSlider = {
                GestureRange:new{ ges = "tap", range = full_screen },
            },
            PanSlider = {
                GestureRange:new{
                    ges = "pan",
                    rate = Screen.low_pan_rate and 4 or 10,
                    range = full_screen,
                },
            },
            PanReleaseSlider = {
                GestureRange:new{ ges = "pan_release", range = full_screen },
            },
        }
    end

    local frame_margin = Screen:scaleBySize(18)
    local frame_padding = Screen:scaleBySize(14)
    local frame_border = Size.border.window
    local frame_width = self.screen_width - 2 * frame_margin
    local inner_width = frame_width - 2 * (frame_border + frame_padding)
    local bottom_gap = Screen:scaleBySize(18)

    self.progress_bar = ProgressWidget:new{
        width = inner_width,
        height = Screen:scaleBySize(36),
        radius = Size.radius.button,
        bgcolor = Blitbuffer.COLOR_GRAY_E,
        fillcolor = Blitbuffer.COLOR_GRAY_5,
        percentage = self:percentageForPage(self.target_page),
        initial_pos_marker = true,
        last = self.page_count,
        ticks = self.ui.toc and self.ui.toc:getTocTicksFlattened() or nil,
        tick_width = Size.line.medium,
        invert_direction = self.ui.view and self.ui.view:shouldInvertBiDiLayoutMirroring() or false,
    }

    self.page_label = TextWidget:new{
        text = self:pageLabel(),
        face = Font:getFace("smallinfofont", 20),
        bold = true,
        max_width = inner_width,
    }

    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{
            w = inner_width,
            h = Screen:scaleBySize(30),
        },
        self.page_label,
    })
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(content, self.progress_bar)

    self.slider_frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = frame_border,
        padding = frame_padding,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }

    self.dimen = Geom:new{
        x = 0,
        y = 0,
        w = self.screen_width,
        h = self.screen_height,
    }
    self[1] = BottomContainer:new{
        dimen = self.dimen,
        VerticalGroup:new{
            align = "center",
            self.slider_frame,
            VerticalSpan:new{ width = bottom_gap },
        },
    }
end

function PageSlider:percentageForPage(page)
    if self.page_count <= 1 then
        return 0
    end
    return (page - 1) / (self.page_count - 1)
end

function PageSlider:pageLabel()
    local percentage = math.floor(self:percentageForPage(self.target_page) * 100 + 0.5)
    return string.format(_("Page %d of %d  ·  %d%%"), self.target_page, self.page_count, percentage)
end

function PageSlider:getTouchArea()
    if not self.progress_bar.dimen then
        return nil
    end

    local extra_height = Screen:scaleBySize(24)
    return Geom:new{
        x = self.progress_bar.dimen.x,
        y = self.progress_bar.dimen.y - extra_height,
        w = self.progress_bar.dimen.w,
        h = self.progress_bar.dimen.h + 2 * extra_height,
    }
end

function PageSlider:updateTargetFromPosition(pos)
    if not pos or not self.progress_bar.dimen then
        return false
    end

    local bar = self.progress_bar.dimen
    local horizontal_margin = self.progress_bar.margin_h or 0
    local clamped_pos = Geom:new{
        x = clamp(
            pos.x,
            bar.x + horizontal_margin,
            bar.x + bar.w - horizontal_margin
        ),
        y = pos.y,
        w = 0,
        h = 0,
    }
    local percentage = self.progress_bar:getPercentageFromPosition(clamped_pos)
    if not percentage then
        return false
    end

    self.target_page = clamp(
        math.floor(percentage * (self.page_count - 1) + 1.5),
        1,
        self.page_count
    )
    self.progress_bar:setPercentage(self:percentageForPage(self.target_page))
    self.page_label:setText(self:pageLabel())
    UIManager:setDirty(self, function()
        return "fast", self.slider_frame.dimen
    end)
    return true
end

function PageSlider:commitTarget()
    if self.target_page ~= self.original_page then
        if self.ui.link then
            self.ui.link:addCurrentLocationToStack()
        end
        self.ui:handleEvent(Event:new("GotoPage", self.target_page))
    end
    UIManager:close(self)
end

function PageSlider:onTapSlider(_, ges_ev)
    local touch_area = self:getTouchArea()
    if pointIsInside(ges_ev.pos, touch_area) then
        if self:updateTargetFromPosition(ges_ev.pos) then
            self:commitTarget()
        end
    elseif self.slider_frame.dimen and not pointIsInside(ges_ev.pos, self.slider_frame.dimen) then
        self:onClose()
    end
    return true
end

function PageSlider:onPanSlider(_, ges_ev)
    if not self.dragging then
        if not pointIsInside(ges_ev.pos, self:getTouchArea()) then
            return true
        end
        self.dragging = true
    end
    self:updateTargetFromPosition(ges_ev.pos)
    return true
end

function PageSlider:onPanReleaseSlider(_, ges_ev)
    if self.dragging then
        self:updateTargetFromPosition(ges_ev.pos)
        self.dragging = nil
        self:commitTarget()
    end
    return true
end

function PageSlider:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function PageSlider:onClose()
    UIManager:close(self)
    return true
end

function PageSlider:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.slider_frame.dimen or self.dimen
    end)
end

local MinimalReaderChrome = InputContainer:extend{}

function MinimalReaderChrome:init()
    self.screen_width = Screen:getWidth()
    self.screen_height = Screen:getHeight()
    self.outer_padding = Screen:scaleBySize(20)
    self.content_width = self.screen_width - 2 * self.outer_padding
    self.gap = Screen:scaleBySize(6)
    self.bottom_mode = self.bottom_mode or "slider"
    self.covers_fullscreen = false

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    if Device:isTouchDevice() then
        self.ges_events.TapOutside = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0,
                    y = 0,
                    w = self.screen_width,
                    h = self.screen_height,
                },
            },
        }
        self.ges_events.SwipeChrome = {
            GestureRange:new{
                ges = "swipe",
                range = Geom:new{
                    x = 0,
                    y = 0,
                    w = self.screen_width,
                    h = self.screen_height,
                },
            },
        }
        if self.show_bottom and self.bottom_mode == "slider" then
            local full_screen = Geom:new{
                x = 0,
                y = 0,
                w = self.screen_width,
                h = self.screen_height,
            }
            self.ges_events.PanBottomSlider = {
                GestureRange:new{
                    ges = "pan",
                    rate = Screen.low_pan_rate and 4 or 10,
                    range = full_screen,
                },
            }
            self.ges_events.PanReleaseBottomSlider = {
                GestureRange:new{ ges = "pan_release", range = full_screen },
            }
        end
    end

    self.dimen = Geom:new{
        x = 0,
        y = 0,
        w = self.screen_width,
        h = self.screen_height,
    }

    local layers = {
        dimen = self.dimen,
        allow_mirroring = false,
    }
    if self.show_top then
        self.top_frame = self:buildTopPanel()
        table.insert(layers, TopContainer:new{
            dimen = self.dimen,
            self.top_frame,
        })
    end
    if self.show_bottom then
        self.bottom_frame = self:buildBottomPanel()
        table.insert(layers, BottomContainer:new{
            dimen = self.dimen,
            self.bottom_frame,
        })
    end
    self[1] = OverlapGroup:new(layers)
end

function MinimalReaderChrome:bookTitle()
    local path = self.ui.document and self.ui.document.file or ""
    local filename = path:match("([^/]+)$") or path
    return cleanBookName(filename).title
end

function MinimalReaderChrome:sectionLabel(text)
    return LeftContainer:new{
        dimen = Geom:new{
            w = self.content_width,
            h = Screen:scaleBySize(24),
        },
        TextWidget:new{
            text = text,
            face = Font:getFace("x_smallinfofont"),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            bold = true,
            max_width = self.content_width,
        },
    }
end

function MinimalReaderChrome:makeButton(text, width, callback)
    return Button:new{
        text = text,
        width = width,
        height = Screen:scaleBySize(40),
        radius = Size.radius.button,
        bordersize = Size.border.default,
        padding_h = Screen:scaleBySize(3),
        text_font_size = 15,
        show_parent = self,
        callback = callback,
    }
end

function MinimalReaderChrome:makeIconButton(icon, width, callback)
    return Button:new{
        icon = icon,
        icon_width = Screen:scaleBySize(22),
        icon_height = Screen:scaleBySize(22),
        width = width,
        height = Screen:scaleBySize(38),
        radius = Size.radius.button,
        bordersize = Size.border.default,
        padding = Screen:scaleBySize(2),
        show_parent = self,
        callback = callback,
    }
end

function MinimalReaderChrome:makeGlyphButton(glyph, width, callback)
    return Button:new{
        text = glyph,
        width = width,
        height = Screen:scaleBySize(38),
        radius = Size.radius.button,
        bordersize = Size.border.default,
        padding = Screen:scaleBySize(2),
        text_font_size = 20,
        text_font_bold = false,
        show_parent = self,
        callback = callback,
    }
end

function MinimalReaderChrome:makeLabeledIconButton(icon, label, width, callback, glyph)
    local button
    if icon then
        button = Button:new{
            icon = icon,
            icon_width = Screen:scaleBySize(23),
            icon_height = Screen:scaleBySize(23),
            width = width,
            height = Screen:scaleBySize(35),
            radius = Size.radius.button,
            bordersize = Size.border.default,
            padding = Screen:scaleBySize(1),
            show_parent = self,
            callback = callback,
        }
    else
        button = Button:new{
            text = glyph,
            width = width,
            height = Screen:scaleBySize(35),
            radius = Size.radius.button,
            bordersize = Size.border.default,
            padding = Screen:scaleBySize(1),
            text_font_size = 21,
            text_font_bold = false,
            show_parent = self,
            callback = callback,
        }
    end

    return VerticalGroup:new{
        align = "center",
        button,
        VerticalSpan:new{ width = Screen:scaleBySize(1) },
        CenterContainer:new{
            dimen = Geom:new{
                w = width,
                h = Screen:scaleBySize(15),
            },
            TextWidget:new{
                text = label,
                face = Font:getFace("x_smallinfofont", 12),
                max_width = width,
            },
        },
    }
end

function MinimalReaderChrome:runAfterClose(callback)
    self:onClose()
    UIManager:nextTick(callback)
end

function MinimalReaderChrome:buildTopPanel()
    local content = VerticalGroup:new{ align = "center" }
    local button_width = math.floor((self.content_width - 5 * self.gap) / 6)

    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(5) })
    table.insert(content, HorizontalGroup:new{
        align = "center",
        self:makeLabeledIconButton("home", _("Home"), button_width, function()
            self:runAfterClose(function()
                self.plugin:openLibraryFromReader()
            end)
        end),
        HorizontalSpan:new{ width = self.gap },
        self:makeLabeledIconButton("book.opened", _("Dict."), button_width, function()
            self:runAfterClose(function()
                self.plugin:showDictionaryLookup()
            end)
        end),
        HorizontalSpan:new{ width = self.gap },
        self:makeLabeledIconButton("star.empty", _("Vocab"), button_width, function()
            self:runAfterClose(function()
                self.plugin:showVocabularyBuilder()
            end)
        end),
        HorizontalSpan:new{ width = self.gap },
        self:makeLabeledIconButton(nil, _("Light"), button_width, function()
            self:runAfterClose(function()
                self.plugin:showLightControl()
            end)
        end, "☼"),
        HorizontalSpan:new{ width = self.gap },
        self:makeLabeledIconButton(nil, _("Night"), button_width, function()
            self:runAfterClose(function()
                self.plugin:toggleNightMode()
            end)
        end, "◐"),
        HorizontalSpan:new{ width = self.gap },
        self:makeLabeledIconButton("exit", _("Power"), button_width, function()
            self:runAfterClose(function()
                self.plugin:showPowerMenu()
            end)
        end),
    })
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(5) })
    table.insert(content, LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{
            w = self.screen_width,
            h = Size.line.medium,
        },
    })

    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        content,
    }
end

function MinimalReaderChrome:wifiButtonText()
    if not Device:hasWifiToggle() then return _("Wi-Fi") end
    local ok, is_on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    return ok and is_on and _("Wi-Fi on") or _("Wi-Fi off")
end

function MinimalReaderChrome:bottomSliderPercentage(page)
    if self.bottom_page_count <= 1 then return 0 end
    return (page - 1) / (self.bottom_page_count - 1)
end

function MinimalReaderChrome:bottomSliderLabel()
    local percentage = math.floor(self:bottomSliderPercentage(self.bottom_target_page) * 100 + 0.5)
    return string.format(_("Page %d of %d  ·  %d%%"), self.bottom_target_page, self.bottom_page_count, percentage)
end

function MinimalReaderChrome:getBottomSliderTouchArea()
    if not self.bottom_progress_bar or not self.bottom_progress_bar.dimen then return nil end
    local extra_height = Screen:scaleBySize(12)
    return Geom:new{
        x = self.bottom_progress_bar.dimen.x,
        y = self.bottom_progress_bar.dimen.y - extra_height,
        w = self.bottom_progress_bar.dimen.w,
        h = self.bottom_progress_bar.dimen.h + 2 * extra_height,
    }
end

function MinimalReaderChrome:updateBottomSliderFromPosition(pos)
    if not pos or not self.bottom_progress_bar or not self.bottom_progress_bar.dimen then return false end
    local bar = self.bottom_progress_bar.dimen
    local horizontal_margin = self.bottom_progress_bar.margin_h or 0
    local clamped_pos = Geom:new{
        x = clamp(pos.x, bar.x + horizontal_margin, bar.x + bar.w - horizontal_margin),
        y = pos.y,
        w = 0,
        h = 0,
    }
    local percentage = self.bottom_progress_bar:getPercentageFromPosition(clamped_pos)
    if not percentage then return false end
    self.bottom_target_page = clamp(
        math.floor(percentage * (self.bottom_page_count - 1) + 1.5),
        1,
        self.bottom_page_count
    )
    self.bottom_progress_bar:setPercentage(self:bottomSliderPercentage(self.bottom_target_page))
    self.bottom_page_label:setText(self:bottomSliderLabel())
    UIManager:setDirty(self, function()
        return "fast", self.bottom_frame.dimen or self.dimen
    end)
    return true
end

function MinimalReaderChrome:commitBottomSlider()
    if self.bottom_target_page ~= self.bottom_original_page then
        if self.ui.link then self.ui.link:addCurrentLocationToStack() end
        self.ui:handleEvent(Event:new("GotoPage", self.bottom_target_page))
    end
    self:onClose()
end

function MinimalReaderChrome:onPanBottomSlider(_, ges_ev)
    if not self.bottom_dragging then
        if not pointIsInside(ges_ev.pos, self:getBottomSliderTouchArea()) then return true end
        self.bottom_dragging = true
    end
    self:updateBottomSliderFromPosition(ges_ev.pos)
    return true
end

function MinimalReaderChrome:onPanReleaseBottomSlider(_, ges_ev)
    if self.bottom_dragging then
        self:updateBottomSliderFromPosition(ges_ev.pos)
        self.bottom_dragging = nil
        self:commitBottomSlider()
    end
    return true
end

function MinimalReaderChrome:buildBottomPanel()
    local content = VerticalGroup:new{ align = "center" }
    local setup_button_width = Screen:scaleBySize(50)
    local label_width = self.content_width - self.gap - setup_button_width

    self.bottom_page_count = math.max(1, self.ui.document:getPageCount())
    self.bottom_original_page = clamp(self.ui:getCurrentPage(), 1, self.bottom_page_count)
    self.bottom_target_page = self.bottom_original_page
    self.bottom_progress_bar = ProgressWidget:new{
        width = self.content_width,
        height = Screen:scaleBySize(30),
        radius = Size.radius.button,
        bgcolor = Blitbuffer.COLOR_GRAY_E,
        fillcolor = Blitbuffer.COLOR_GRAY_5,
        percentage = self:bottomSliderPercentage(self.bottom_target_page),
        last = self.bottom_page_count,
        ticks = self.ui.toc and self.ui.toc:getTocTicksFlattened() or nil,
        tick_width = Size.line.medium,
        invert_direction = self.ui.view and self.ui.view:shouldInvertBiDiLayoutMirroring() or false,
    }
    self.bottom_page_label = TextWidget:new{
        text = self:bottomSliderLabel(),
        face = Font:getFace("smallinfofont"),
        bold = true,
        max_width = label_width,
    }

    table.insert(content, LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{
            w = self.screen_width,
            h = Size.line.medium,
        },
    })
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(content, HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = label_width, h = Screen:scaleBySize(40) },
            self.bottom_page_label,
        },
        HorizontalSpan:new{ width = self.gap },
        self:makeIconButton("appbar.typeset", setup_button_width, function()
            self:runAfterClose(function()
                self.plugin:showFontSettings()
            end)
        end),
    })
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    table.insert(content, self.bottom_progress_bar)
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(8) })

    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        content,
    }
end

function MinimalReaderChrome:onTapOutside(_, ges_ev)
    if self.show_bottom and self.bottom_mode == "slider"
            and pointIsInside(ges_ev.pos, self:getBottomSliderTouchArea()) then
        if self:updateBottomSliderFromPosition(ges_ev.pos) then self:commitBottomSlider() end
        return true
    end
    local inside_top = self.top_frame and pointIsInside(ges_ev.pos, self.top_frame.dimen)
    local inside_bottom = self.bottom_frame and pointIsInside(ges_ev.pos, self.bottom_frame.dimen)
    if not inside_top and not inside_bottom then
        self:onClose()
    end
    return true
end

function MinimalReaderChrome:onSwipeChrome(_, ges_ev)
    if ges_ev.direction == "south" and not self.show_top then
        self.plugin:showReaderChrome(true, self.show_bottom, self.bottom_mode)
        return true
    elseif ges_ev.direction == "north" and self.ui.document and not self.show_bottom then
        self.plugin:showReaderChrome(self.show_top, true, "slider")
        return true
    end
    return false
end

function MinimalReaderChrome:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function MinimalReaderChrome:onClose()
    UIManager:close(self)
    return true
end

function MinimalReaderChrome:onCloseWidget()
    if self.plugin and self.plugin.reader_chrome == self then
        self.plugin.reader_chrome = nil
    end
    UIManager:setDirty(nil, "ui")
end

local function normalizePath(path)
    if not path or path == "" then
        return nil
    end
    local real_path = FFIUtil.realpath(path)
    path = real_path or path
    if path ~= "/" then
        path = path:gsub("/+$", "")
    end
    return path
end

local function pathIsInside(path, root)
    path = normalizePath(path)
    root = normalizePath(root)
    return path and root and (path == root or path:sub(1, #root + 1) == root .. "/")
end

local RoundedRectWidget = Widget:extend{}

function RoundedRectWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function RoundedRectWidget:getSize()
    return self.dimen
end

function RoundedRectWidget:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    local radius = math.min(self.radius or 0, math.floor(math.min(self.width, self.height) / 2))
    if radius > 0 then
        bb:paintRoundedRect(x, y, self.width, self.height, self.background, radius)
        -- Keep the outer corner rounded while the reading position itself
        -- remains a clean, unoutlined grayscale boundary.
        if self.square_right and self.width > radius then
            bb:paintRect(x + radius, y, self.width - radius, self.height, self.background)
        end
    else
        bb:paintRect(x, y, self.width, self.height, self.background)
    end
end

local BookProgressCard = InputContainer:extend{}

function BookProgressCard:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local border = Size.border.default
    local inner_width = self.width - 2 * border
    local inner_height = self.height - 2 * border
    local fill_width = math.floor(inner_width * clamp(self.percentage or 0, 0, 1) + 0.5)
    local layers = {
        dimen = self.dimen,
        allow_mirroring = false,
        RoundedRectWidget:new{
            background = Blitbuffer.COLOR_WHITE,
            width = self.width,
            height = self.height,
            radius = Size.radius.button,
        },
    }

    if fill_width > 0 then
        local progress_fill = RoundedRectWidget:new{
            -- This is intentionally a mid-gray: clearly darker in normal
            -- mode, and automatically clearly lighter after night inversion.
            background = Blitbuffer.COLOR_GRAY,
            width = fill_width,
            height = inner_height,
            radius = Size.radius.button - border,
            square_right = fill_width < inner_width,
        }
        progress_fill.overlap_offset = { border, border }
        table.insert(layers, progress_fill)

    end

    table.insert(layers, self.content)
    self[1] = OverlapGroup:new(layers)

    if Device:isTouchDevice() then
        self.ges_events = {
            TapCard = {
                GestureRange:new{ ges = "tap", range = self.dimen },
            },
            HoldCard = {
                GestureRange:new{ ges = "hold", range = self.dimen },
            },
        }
    end
end

function BookProgressCard:onTapCard()
    if self.callback then
        self.callback()
    end
    return true
end

function BookProgressCard:onHoldCard()
    if self.hold_callback then
        self.hold_callback()
    end
    return true
end

local LibraryDashboard = InputContainer:extend{}

function LibraryDashboard:init()
    self.screen_width = Screen:getWidth()
    self.screen_height = Screen:getHeight()
    self.outer_padding = Screen:scaleBySize(18)
    self.content_width = self.screen_width - 2 * self.outer_padding
    self.library_root = self.plugin:getLibraryRoot()
    self.current_dir = normalizePath(self.plugin.library_current_dir)
    if not self.current_dir or not pathIsInside(self.current_dir, self.library_root)
            or lfs.attributes(self.current_dir, "mode") ~= "directory" then
        self.current_dir = self.library_root
    end
    self.plugin.library_current_dir = self.current_dir

    self.pending_cover_jobs = {}
    self.search_query = self.plugin.library_search_query or ""
    self.sort_mode = G_reader_settings:readSetting("minimal_library_sort_mode") or "recent"
    if self.sort_mode ~= "recent" and self.sort_mode ~= "added" then
        self.sort_mode = "recent"
    end
    self.added_times = G_reader_settings:readSetting("minimal_library_added_times") or {}
    self.seed_added_times = next(self.added_times) == nil
    self.added_times_changed = false

    local current_books = self:scanBooks(self.current_dir)
    self.total_books = self.current_dir == self.library_root and current_books or self:scanBooks(self.library_root)
    if self.added_times_changed then
        G_reader_settings:saveSetting("minimal_library_added_times", self.added_times)
    end
    self.books = self:filterAndSortBooks(current_books)
    self.page_count = math.max(1, math.ceil(#self.books / MAX_VISIBLE_BOOKS))
    self.page = clamp(self.plugin.library_page or 1, 1, self.page_count)
    self.plugin.library_page = self.page
    self.covers_fullscreen = true
    self.key_events.Close = { { Device.input.group.Back } }

    self[1] = FrameContainer:new{
        width = self.screen_width,
        height = self.screen_height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        self:buildContent(),
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_width, h = self.screen_height }
    if Device:isTouchDevice() then
        self.ges_events.SwipeDashboard = {
            GestureRange:new{
                ges = "swipe",
                range = self.dimen,
            },
        }
    end

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)

    if next(self.pending_cover_jobs) then
        UIManager:nextTick(function()
            self:startCoverExtraction()
        end)
    end
end

function LibraryDashboard:relativePath(path)
    path = normalizePath(path)
    if not path or path == self.library_root then
        return ""
    end
    return path:sub(#self.library_root + 2)
end

function LibraryDashboard:categoryLabel()
    local relative = self:relativePath(self.current_dir)
    return relative == "" and _("All books") or relative
end

function LibraryDashboard:scanBooks(root)
    local books = {}

    local function walk(path, depth)
        if depth > MAX_SCAN_DEPTH or #books >= MAX_SCANNED_BOOKS then
            return
        end
        local ok, iterator, directory = pcall(lfs.dir, path)
        if not ok then
            return
        end
        for entry in iterator, directory do
            if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
                local full_path = path .. "/" .. entry
                local mode = lfs.attributes(full_path, "mode")
                if mode == "file" then
                    local extension = entry:match("%.([^%.]+)$")
                    extension = extension and extension:lower()
                    if extension and SUPPORTED_EXTENSIONS[extension] then
                        local book = cleanBookName(entry)
                        book.path = full_path
                        book.filename = entry
                        book.directory = path
                        book.category = self:relativePath(path)
                        book.added_time = tonumber(self.added_times[full_path])
                        if not book.added_time then
                            if self.seed_added_times then
                                book.added_time = lfs.attributes(full_path, "modification") or os.time()
                            else
                                -- Once the library has been indexed, the first time a path is
                                -- seen is the closest reliable definition of "added" on MTP.
                                book.added_time = os.time()
                            end
                            self.added_times[full_path] = book.added_time
                            self.added_times_changed = true
                        end
                        table.insert(books, book)
                        if #books >= MAX_SCANNED_BOOKS then
                            return
                        end
                    end
                elseif mode == "directory" and not entry:match("%.sdr$") then
                    walk(full_path, depth + 1)
                end
            end
        end
    end

    walk(root, 1)
    return books
end

function LibraryDashboard:filterAndSortBooks(books)
    ReadHistory:reload()
    local opened_times = {}
    for _, item in ipairs(ReadHistory.hist) do
        opened_times[item.file] = item.time or 0
    end

    local query = self.search_query:match("^%s*(.-)%s*$"):lower()
    local filtered = {}
    for _, book in ipairs(books) do
        book.opened_time = opened_times[book.path] or 0
        local searchable = table.concat({
            book.title or "",
            book.author or "",
            book.filename or "",
            book.category or "",
            book.format or "",
        }, " "):lower()
        if query == "" or searchable:find(query, 1, true) then
            table.insert(filtered, book)
        end
    end

    local sort_mode = self.sort_mode
    local function titleBefore(left, right)
        local left_title = (left.title or left.filename or ""):lower()
        local right_title = (right.title or right.filename or ""):lower()
        if left_title == right_title then return left.path < right.path end
        return left_title < right_title
    end

    table.sort(filtered, function(left, right)
        local left_primary
        local right_primary
        local left_secondary
        local right_secondary
        if sort_mode == "added" then
            left_primary, right_primary = left.added_time or 0, right.added_time or 0
            left_secondary, right_secondary = left.opened_time or 0, right.opened_time or 0
        else
            left_primary, right_primary = left.opened_time or 0, right.opened_time or 0
            left_secondary, right_secondary = left.added_time or 0, right.added_time or 0
        end
        if left_primary ~= right_primary then return left_primary > right_primary end
        if left_secondary ~= right_secondary then return left_secondary > right_secondary end
        return titleBefore(left, right)
    end)
    return filtered
end

function LibraryDashboard:setSortMode(mode)
    if mode ~= "recent" and mode ~= "added" then return end
    G_reader_settings:saveSetting("minimal_library_sort_mode", mode)
    self.plugin.library_page = 1
    self:refreshDashboard()
end

function LibraryDashboard:showSearchDialog()
    local dialog
    local function applySearch(query)
        self.plugin.library_search_query = query:match("^%s*(.-)%s*$")
        self.plugin.library_page = 1
        UIManager:close(dialog)
        self:refreshDashboard()
    end

    dialog = InputDialog:new{
        title = _("Search library"),
        input = self.search_query,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Clear"),
                callback = function() applySearch("") end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function() applySearch(dialog:getInputText()) end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    UIManager:nextTick(function()
        UIManager:setDirty(nil, "ui")
    end)
end

function LibraryDashboard:sortLabel()
    return self.sort_mode == "added" and _("Added ↓") or _("Opened ↓")
end

function LibraryDashboard:searchLabel()
    if self.search_query == "" then return _("Search books…") end
    return string.format(_("Search: %s"), self.search_query)
end

function LibraryDashboard:bookCountText()
    local count = #self.books
    if self.search_query ~= "" then
        if count == 1 then return _("1 match") end
        return string.format(_("%d matches"), count)
    end
    if count == 1 then return _("1 book") end
    return string.format(_("%d books"), count)
end

function LibraryDashboard:subtitleText()
    local parts = {
        self:bookCountText(),
        self:categoryLabel(),
    }
    local battery = self.plugin:getHeaderBatteryText()
    if battery ~= "" then
        table.insert(parts, battery)
    end
    return table.concat(parts, "  ·  ")
end

function LibraryDashboard:collectFolders(root)
    local folders = {}
    local function walk(path, depth)
        if depth > MAX_SCAN_DEPTH or #folders >= 150 then return end
        local ok, iterator, directory = pcall(lfs.dir, path)
        if not ok then return end
        local children = {}
        for entry in iterator, directory do
            if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." and not entry:match("%.sdr$") then
                local full_path = path .. "/" .. entry
                if lfs.attributes(full_path, "mode") == "directory" then
                    table.insert(children, { name = entry, path = full_path })
                end
            end
        end
        table.sort(children, function(left, right)
            return left.name:lower() < right.name:lower()
        end)
        for _, child in ipairs(children) do
            table.insert(folders, child)
            walk(child.path, depth + 1)
        end
    end
    walk(root, 1)
    return folders
end

function LibraryDashboard:listChildFolders(path)
    local folders = {}
    local ok, iterator, directory = pcall(lfs.dir, path)
    if not ok then return folders end
    for entry in iterator, directory do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." and not entry:match("%.sdr$") then
            local full_path = path .. "/" .. entry
            if lfs.attributes(full_path, "mode") == "directory" then
                table.insert(folders, { name = entry, path = normalizePath(full_path) })
            end
        end
    end
    table.sort(folders, function(left, right)
        return left.name:lower() < right.name:lower()
    end)
    return folders
end

function LibraryDashboard:sectionLabel(text)
    return LeftContainer:new{
        dimen = Geom:new{ w = self.content_width, h = Screen:scaleBySize(24) },
        TextWidget:new{
            text = text,
            face = Font:getFace("x_smallinfofont"),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            bold = true,
            max_width = self.content_width,
        },
    }
end

function LibraryDashboard:getBookInfoManager()
    if self.book_info_manager_checked then
        return self.book_info_manager
    end
    self.book_info_manager_checked = true
    local ok, manager = pcall(require, "bookinfomanager")
    if ok then self.book_info_manager = manager end
    return self.book_info_manager
end

function LibraryDashboard:loadBookDetails(book, cover_width, cover_height)
    local ok, progress_info = pcall(BookList.getBookInfo, book.path)
    if not ok then progress_info = {} end
    progress_info = progress_info or {}
    book.percentage = tonumber(progress_info.percent_finished) or 0
    if progress_info.status == "complete" then book.percentage = 1 end
    book.percentage = clamp(book.percentage, 0, 1)
    book.pages = tonumber(progress_info.pages)

    local manager = self:getBookInfoManager()
    if not manager then return end
    local got_info, cover_info = pcall(manager.getBookInfo, manager, book.path, true)
    if not got_info then cover_info = nil end
    if cover_info then
        book.pages = book.pages or tonumber(cover_info.pages)
        if cover_info.title and cover_info.title ~= "" and not cover_info.ignore_meta then
            book.title = cover_info.title
        end
        if cover_info.authors and cover_info.authors ~= "" and not cover_info.ignore_meta then
            book.author = cover_info.authors
        end
        book.cover_info = cover_info
    end
    if not cover_info or (not cover_info.cover_fetched and not cover_info.ignore_cover) then
        self.pending_cover_jobs[book.path] = {
            filepath = book.path,
            cover_specs = { max_cover_w = cover_width, max_cover_h = cover_height },
        }
    end
end

function LibraryDashboard:startCoverExtraction()
    local manager = self:getBookInfoManager()
    if not manager or self.cover_jobs_started or self.plugin.dashboard ~= self then return end
    local jobs = {}
    for _, job in pairs(self.pending_cover_jobs) do table.insert(jobs, job) end
    if #jobs == 0 then return end
    self.cover_jobs_started = true
    local ok, started = pcall(manager.extractInBackground, manager, jobs)
    if not ok or started == false then return end

    local function checkFinished()
        if self.plugin.dashboard ~= self then return end
        local status_ok, busy = pcall(manager.isExtractingInBackground, manager)
        if status_ok and busy then
            UIManager:scheduleIn(0.75, checkFinished)
        else
            self:refreshDashboard()
        end
    end
    UIManager:scheduleIn(0.75, checkFinished)
end

function LibraryDashboard:makeCover(book, area_width, area_height)
    local cover_width = area_width - 2 * Size.border.default
    local cover_height = area_height - 2 * Size.border.default
    local info = book.cover_info
    local cover
    if info and info.has_cover and not info.ignore_cover and info.cover_bb then
        local scale_factor = 0
        local manager = self:getBookInfoManager()
        if manager and info.cover_w and info.cover_h then
            local ok, scaled_width, scaled_height, fitted_scale = pcall(
                manager.getCachedCoverSize, info.cover_w, info.cover_h, cover_width, cover_height
            )
            if ok and scaled_width and scaled_height and fitted_scale then
                scale_factor = fitted_scale
            end
        end
        cover = ImageWidget:new{
            image = info.cover_bb,
            width = cover_width,
            height = cover_height,
            scale_factor = scale_factor,
        }
    else
        if info and info.cover_bb then info.cover_bb:free() end
        local initial = book.title:match("%w") or "B"
        cover = CenterContainer:new{
            dimen = Geom:new{ w = cover_width, h = cover_height },
            TextWidget:new{
                text = initial:upper(),
                face = Font:getFace("tfont", 28),
                bold = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = area_width, h = area_height },
        FrameContainer:new{
            radius = Size.radius.default,
            bordersize = Size.border.default,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            cover,
        },
    }
end

function LibraryDashboard:makeBookCard(book)
    local card_width = self.content_width
    -- Five rows fill the 632 x 840 Paperwhite layout without crowding. Pages
    -- with navigation end above the controls; a single-page library reclaims
    -- that footer area for slightly taller cards.
    local row_height = self.page_count > 1 and 108 or 120
    local card_height = Screen:scaleBySize(row_height)
    local border = Size.border.default
    local padding = Screen:scaleBySize(4)
    local inner_width = card_width - 2 * (border + padding)
    local cover_area_height = card_height - 2 * (border + padding)
    local cover_area_width = math.floor(cover_area_height * 0.70)
    local gap = Screen:scaleBySize(5)
    local move_width = Screen:scaleBySize(52)
    local right_balance = Screen:scaleBySize(4)
    local details_width = inner_width - cover_area_width - move_width - 2 * gap - right_balance

    self:loadBookDetails(book, cover_area_width, cover_area_height)
    local percent_number = math.floor(book.percentage * 100 + 0.5)
    local pages_text
    if book.pages then
        local pages_read = clamp(math.floor(book.pages * book.percentage + 0.5), 0, book.pages)
        pages_text = string.format(_("%d / %d pages read"), pages_read, book.pages)
    else
        pages_text = _("Pages available after opening")
    end
    local secondary_text = string.format("%s  ·  %s", book.author, book.format)
    if book.category ~= "" then
        secondary_text = string.format("%s  ·  %s", secondary_text, book.category)
    end

    local details = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = book.title,
            face = Font:getFace("smallinfofont", 16),
            bold = true,
            max_width = details_width,
        },
        TextWidget:new{
            text = secondary_text,
            face = Font:getFace("x_smallinfofont"),
            fgcolor = Blitbuffer.COLOR_GRAY_4,
            max_width = details_width,
        },
        TextWidget:new{
            text = string.format("%s  ·  %d%%", pages_text, percent_number),
            face = Font:getFace("smallinfofont", 15),
            bold = true,
            max_width = details_width,
        },
    }
    local details_size = details:getSize()
    local details_container = TopContainer:new{
        dimen = Geom:new{ w = details_width, h = cover_area_height },
        LeftContainer:new{
            dimen = Geom:new{ w = details_width, h = details_size.h },
            details,
        },
    }

    local content = FrameContainer:new{
        width = card_width,
        height = card_height,
        radius = Size.radius.button,
        bordersize = border,
        padding = padding,
        margin = 0,
        background = nil,
        HorizontalGroup:new{
            align = "center",
            self:makeCover(book, cover_area_width, cover_area_height),
            HorizontalSpan:new{ width = gap },
            details_container,
            HorizontalSpan:new{ width = gap },
            Button:new{
                text = _("Move"),
                width = move_width,
                height = Screen:scaleBySize(30),
                radius = Size.radius.button,
                bordersize = Size.border.default,
                padding_h = Screen:scaleBySize(3),
                text_font_size = 14,
                show_parent = self,
                callback = function()
                    self:showMoveMenu(book)
                end,
            },
            HorizontalSpan:new{ width = right_balance },
        },
    }

    return BookProgressCard:new{
        width = card_width,
        height = card_height,
        percentage = book.percentage,
        content = content,
        callback = function() self:openBook(book) end,
        hold_callback = function() self:showMoveMenu(book) end,
    }
end

function LibraryDashboard:openBook(book)
    if not book or lfs.attributes(book.path, "mode") ~= "file" then return end
    FileManagerUtil.openFile(self.ui, book.path, function()
        UIManager:close(self)
    end, true)
end

function LibraryDashboard:refreshDashboard()
    if self.plugin.dashboard == self then self.plugin.dashboard = nil end
    UIManager:close(self)
    -- Show the replacement in the same UI cycle so the stock file manager
    -- never becomes visible between Library redraws.
    self.plugin:showDashboard()
end

function LibraryDashboard:navigateTo(path)
    path = normalizePath(path)
    if not pathIsInside(path, self.library_root) or lfs.attributes(path, "mode") ~= "directory" then
        return
    end
    self.plugin.library_current_dir = path
    self.plugin.library_page = 1
    self:refreshDashboard()
end

function LibraryDashboard:updateBookLocation(old_path, new_path, added_times)
    pcall(DocSettings.updateLocation, old_path, new_path)
    pcall(ReadHistory.updateItem, ReadHistory, old_path, new_path)
    pcall(ReadCollection.updateItem, ReadCollection, old_path, new_path)
    BookList.resetBookInfoCache(old_path)
    BookList.resetBookInfoCache(new_path)
    added_times[new_path] = added_times[old_path] or os.time()
    added_times[old_path] = nil
    if G_reader_settings:readSetting("lastfile") == old_path then
        G_reader_settings:saveSetting("lastfile", new_path)
    end
end

function LibraryDashboard:removeCategory(path)
    path = normalizePath(path)
    if not path or path == self.library_root or not pathIsInside(path, self.library_root)
            or lfs.attributes(path, "mode") ~= "directory" then
        return
    end

    local parent = normalizePath(FFIUtil.dirname(path))
    local books = self:scanBooks(path)
    local entries = {}
    local ok, iterator, directory = pcall(lfs.dir, path)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("The category could not be opened."),
            icon = "notice-warning",
        })
        return
    end

    for entry in iterator, directory do
        if entry ~= "." and entry ~= ".." then
            local source = path .. "/" .. entry
            local destination = parent .. "/" .. entry
            if lfs.attributes(destination) then
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        _("Cannot remove this category because ‘%s’ already exists in %s. Move or rename it first."),
                        entry,
                        getFolderName(parent)
                    ),
                    icon = "notice-warning",
                })
                return
            end
            table.insert(entries, { source = source, destination = destination })
        end
    end

    local moved = {}
    for _, entry in ipairs(entries) do
        local renamed = os.rename(entry.source, entry.destination)
        if not renamed then
            for index = #moved, 1, -1 do
                os.rename(moved[index].destination, moved[index].source)
            end
            UIManager:show(InfoMessage:new{
                text = _("The category could not be removed. Its contents were left in place."),
                icon = "notice-warning",
            })
            return
        end
        table.insert(moved, entry)
    end

    local removed = lfs.rmdir(path)
    if not removed then
        for index = #moved, 1, -1 do
            os.rename(moved[index].destination, moved[index].source)
        end
        UIManager:show(InfoMessage:new{
            text = _("The category folder could not be removed. Its contents were left in place."),
            icon = "notice-warning",
        })
        return
    end

    local added_times = G_reader_settings:readSetting("minimal_library_added_times") or {}
    for _, book in ipairs(books) do
        local new_path = parent .. book.path:sub(#path + 1)
        self:updateBookLocation(book.path, new_path, added_times)
    end
    G_reader_settings:saveSetting("minimal_library_added_times", added_times)

    if pathIsInside(self.current_dir, path) then
        self.plugin.library_current_dir = parent .. self.current_dir:sub(#path + 1)
    end
    self.plugin.library_page = 1
    self:refreshDashboard()
    UIManager:show(InfoMessage:new{ text = _("Category removed; its contents were moved up one level") })
end

function LibraryDashboard:confirmRemoveCategory(folder)
    local parent = normalizePath(FFIUtil.dirname(folder.path))
    UIManager:show(ConfirmBox:new{
        text = string.format(
            _("Remove the category “%s”?\n\nIts books and subcategories will be moved into “%s”. No books will be deleted."),
            self:relativePath(folder.path),
            parent == self.library_root and _("All books") or self:relativePath(parent)
        ),
        ok_text = _("Remove category"),
        ok_callback = function()
            self:removeCategory(folder.path)
        end,
    })
end

function LibraryDashboard:showRemoveCategoryMenu()
    local remove_menu
    local items = {}
    for _, folder in ipairs(self:collectFolders(self.library_root)) do
        table.insert(items, {
            text = self:relativePath(folder.path),
            mandatory = string.format("%d", #self:scanBooks(folder.path)),
            callback = function()
                UIManager:close(remove_menu)
                self:confirmRemoveCategory(folder)
            end,
        })
    end
    remove_menu = Menu:new{
        title = _("Remove category"),
        subtitle = _("Books are moved up one level, not deleted"),
        item_table = items,
        items_per_page = 8,
        width = math.floor(self.screen_width * 0.9),
        height = math.floor(self.screen_height * 0.82),
        show_parent = self,
    }
    UIManager:show(remove_menu)
end

function LibraryDashboard:showCategories()
    local category_menu
    local folders = self:collectFolders(self.library_root)
    local items = {
        {
            text = _("All books"),
            mandatory = string.format("%d", #self.total_books),
            checked = self.current_dir == self.library_root,
            callback = function()
                UIManager:close(category_menu)
                self:navigateTo(self.library_root)
            end,
        },
    }
    for _, folder in ipairs(folders) do
        local book_count = #self:scanBooks(folder.path)
        table.insert(items, {
            text = self:relativePath(folder.path),
            mandatory = string.format("%d", book_count),
            checked = self.current_dir == folder.path,
            callback = function()
                UIManager:close(category_menu)
                self:navigateTo(folder.path)
            end,
        })
    end
    if #items == 1 then
        table.insert(items, {
            text = _("No categories yet — use New category"),
            dim = true,
        })
    else
        table.insert(items, {
            text = _("Remove a category…"),
            mandatory = "−",
            separator = true,
            callback = function()
                UIManager:close(category_menu)
                self:showRemoveCategoryMenu()
            end,
        })
    end
    category_menu = Menu:new{
        title = _("Categories"),
        subtitle = _("Choose a category to filter the library"),
        item_table = items,
        items_per_page = 8,
        width = math.floor(self.screen_width * 0.9),
        height = math.floor(self.screen_height * 0.82),
        show_parent = self,
    }
    UIManager:show(category_menu)
end

function LibraryDashboard:promptCreateFolder(parent, after_create)
    parent = normalizePath(parent)
    if not pathIsInside(parent, self.library_root) and not pathIsInside(parent, self.plugin:getDirectoryChooserRoot()) then
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("New category"),
        description = string.format(_("Create inside: %s"), getFolderName(parent)),
        input_hint = _("Category name"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Create"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    if name == "" or name == "." or name == ".." or name:find("[/\\:]") then
                        UIManager:show(InfoMessage:new{
                            text = _("Use a simple category name without slashes or colons."),
                            icon = "notice-warning",
                        })
                        return
                    end
                    local new_path = parent .. "/" .. name
                    if lfs.attributes(new_path) then
                        UIManager:show(InfoMessage:new{
                            text = _("A file or category with that name already exists."),
                            icon = "notice-warning",
                        })
                        return
                    end
                    local ok, made = pcall(lfs.mkdir, new_path)
                    if not ok or not made then
                        UIManager:show(InfoMessage:new{
                            text = _("Could not create the category."),
                            icon = "notice-warning",
                        })
                        return
                    end
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = _("Category created") })
                    if after_create then after_create(normalizePath(new_path)) end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    -- Force one complete composited repaint after the keyboard is placed.
    -- This prevents an underlying rounded book-card border from being left
    -- across the dialog on e-ink partial refreshes.
    UIManager:nextTick(function()
        UIManager:setDirty(nil, "ui")
    end)
end

function LibraryDashboard:moveBook(book, destination_dir)
    destination_dir = normalizePath(destination_dir)
    if not destination_dir or not pathIsInside(destination_dir, self.library_root) then return end
    if normalizePath(book.directory) == destination_dir then
        UIManager:show(InfoMessage:new{ text = _("This book is already in that category.") })
        return
    end
    local destination = destination_dir .. "/" .. book.filename
    if lfs.attributes(destination) then
        UIManager:show(InfoMessage:new{
            text = _("A book with the same filename already exists in that category."),
            icon = "notice-warning",
        })
        return
    end

    local moved
    if self.ui and self.ui.moveFile then
        moved = self.ui:moveFile(book.path, destination)
    else
        moved = os.rename(book.path, destination) and true or false
    end
    if not moved then
        UIManager:show(InfoMessage:new{
            text = _("The book could not be moved."),
            icon = "notice-warning",
        })
        return
    end

    pcall(DocSettings.updateLocation, book.path, destination)
    pcall(ReadHistory.updateItem, ReadHistory, book.path, destination)
    pcall(ReadCollection.updateItem, ReadCollection, book.path, destination)
    BookList.resetBookInfoCache(book.path)
    BookList.resetBookInfoCache(destination)
    local added_times = G_reader_settings:readSetting("minimal_library_added_times") or {}
    added_times[destination] = added_times[book.path] or book.added_time or os.time()
    added_times[book.path] = nil
    G_reader_settings:saveSetting("minimal_library_added_times", added_times)
    if G_reader_settings:readSetting("lastfile") == book.path then
        G_reader_settings:saveSetting("lastfile", destination)
    end
    UIManager:show(InfoMessage:new{ text = _("Book moved") })
    self:refreshDashboard()
end

function LibraryDashboard:showMoveMenu(book)
    local move_menu
    local items = {
        {
            text = _("Library root"),
            mandatory = normalizePath(book.directory) == self.library_root and _("Current") or nil,
            callback = function()
                UIManager:close(move_menu)
                self:moveBook(book, self.library_root)
            end,
        },
    }
    for _, folder in ipairs(self:collectFolders(self.library_root)) do
        table.insert(items, {
            text = self:relativePath(folder.path),
            mandatory = normalizePath(book.directory) == folder.path and _("Current") or nil,
            callback = function()
                UIManager:close(move_menu)
                self:moveBook(book, folder.path)
            end,
        })
    end
    move_menu = Menu:new{
        title = _("Move book"),
        subtitle = book.title,
        item_table = items,
        items_per_page = 8,
        width = math.floor(self.screen_width * 0.9),
        height = math.floor(self.screen_height * 0.82),
        show_parent = self,
    }
    UIManager:show(move_menu)
end

function LibraryDashboard:showDirectoryPicker(path)
    local chooser_root = self.plugin:getDirectoryChooserRoot()
    path = normalizePath(path) or chooser_root
    if not pathIsInside(path, chooser_root) or lfs.attributes(path, "mode") ~= "directory" then
        path = chooser_root
    end
    local picker
    local items = {
        {
            text = _("Use this folder"),
            mandatory = "✓",
            callback = function()
                UIManager:close(picker)
                self.plugin:setLibraryRoot(path)
                self:refreshDashboard()
            end,
        },
        {
            text = _("New category here"),
            mandatory = "+",
            callback = function()
                UIManager:close(picker)
                self:promptCreateFolder(path, function(new_path)
                    self:showDirectoryPicker(new_path)
                end)
            end,
        },
    }
    if path ~= chooser_root then
        table.insert(items, {
            text = _("Parent folder"),
            mandatory = "↑",
            callback = function()
                UIManager:close(picker)
                self:showDirectoryPicker(FFIUtil.dirname(path))
            end,
        })
    end
    for _, folder in ipairs(self:listChildFolders(path)) do
        table.insert(items, {
            text = folder.name,
            mandatory = "›",
            callback = function()
                UIManager:close(picker)
                self:showDirectoryPicker(folder.path)
            end,
        })
    end
    local relative = path == chooser_root and getFolderName(chooser_root) or path:sub(#chooser_root + 2)
    picker = Menu:new{
        title = _("Library folder"),
        subtitle = relative,
        item_table = items,
        items_per_page = 8,
        width = math.floor(self.screen_width * 0.92),
        height = math.floor(self.screen_height * 0.86),
        show_parent = self,
    }
    UIManager:show(picker)
end

function LibraryDashboard:showSettings()
    local settings_menu
    settings_menu = Menu:new{
        title = _("Library settings"),
        subtitle = self.library_root,
        item_table = {
            {
                text = _("Change library folder"),
                callback = function()
                    UIManager:close(settings_menu)
                    self:showDirectoryPicker(self.library_root)
                end,
            },
            {
                text = _("Refresh library"),
                callback = function()
                    UIManager:close(settings_menu)
                    self:refreshDashboard()
                end,
            },
        },
        width = math.floor(self.screen_width * 0.9),
        height = math.floor(self.screen_height * 0.45),
        show_parent = self,
    }
    UIManager:show(settings_menu)
end

function LibraryDashboard:makeToolbar()
    local gap = Screen:scaleBySize(8)
    local button_width = math.floor((self.content_width - gap) / 2)
    local function toolbarButton(text, callback)
        return Button:new{
            text = text,
            width = button_width,
            height = Screen:scaleBySize(44),
            radius = Size.radius.button,
            bordersize = Size.border.default,
            padding_h = Screen:scaleBySize(4),
            text_font_size = 16,
            show_parent = self,
            callback = callback,
        }
    end
    return HorizontalGroup:new{
        align = "center",
        toolbarButton(_("Categories"), function() self:showCategories() end),
        HorizontalSpan:new{ width = gap },
        toolbarButton(_("New category"), function()
            self:promptCreateFolder(self.current_dir, function() self:refreshDashboard() end)
        end),
    }
end

function LibraryDashboard:makeHeaderActions()
    local gap = Screen:scaleBySize(6)
    local button_width = Screen:scaleBySize(42)
    local sort_width = math.floor(self.content_width * 0.23)
    local search_width = self.content_width - 2 * button_width - sort_width - 3 * gap
    local function iconButton(icon, callback)
        return Button:new{
            icon = icon,
            icon_width = Screen:scaleBySize(20),
            icon_height = Screen:scaleBySize(20),
            width = button_width,
            height = Screen:scaleBySize(38),
            radius = Size.radius.button,
            bordersize = Size.border.default,
            padding = Screen:scaleBySize(2),
            show_parent = self,
            callback = callback,
        }
    end
    return HorizontalGroup:new{
        align = "center",
        iconButton("appbar.filebrowser", function() self:showCategories() end),
        HorizontalSpan:new{ width = gap },
        iconButton("plus", function()
            self:promptCreateFolder(self.current_dir, function() self:refreshDashboard() end)
        end),
        HorizontalSpan:new{ width = gap },
        Button:new{
            text = self:searchLabel(),
            align = "left",
            width = search_width,
            height = Screen:scaleBySize(38),
            radius = Size.radius.button,
            bordersize = Size.border.default,
            padding_h = Screen:scaleBySize(8),
            text_font_face = "smallinfofont",
            text_font_size = 15,
            text_font_bold = false,
            show_parent = self,
            callback = function() self:showSearchDialog() end,
        },
        HorizontalSpan:new{ width = gap },
        Button:new{
            text = self:sortLabel(),
            width = sort_width,
            height = Screen:scaleBySize(38),
            radius = Size.radius.button,
            bordersize = Size.border.default,
            padding_h = Screen:scaleBySize(4),
            text_font_face = "smallinfofont",
            text_font_size = 14,
            text_font_bold = true,
            show_parent = self,
            callback = function()
                self:setSortMode(self.sort_mode == "recent" and "added" or "recent")
            end,
        },
    }
end

function LibraryDashboard:makeBookList()
    local list = VerticalGroup:new{ align = "left" }
    if #self.books == 0 then
        local empty_text = self.search_query ~= ""
            and _("No books match your search. Tap the search bar to change or clear it.")
            or _("No books in this category. Add books here, create a subcategory, or choose another category.")
        table.insert(list, FrameContainer:new{
            width = self.content_width,
            height = Screen:scaleBySize(134),
            radius = Size.radius.button,
            bordersize = Size.border.default,
            padding = Screen:scaleBySize(10),
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.content_width - Screen:scaleBySize(22),
                    h = Screen:scaleBySize(112),
                },
                TextBoxWidget:new{
                    text = empty_text,
                    face = Font:getFace("smallinfofont"),
                    width = self.content_width - Screen:scaleBySize(50),
                    alignment = "center",
                },
            },
        })
        return list
    end

    local first = (self.page - 1) * MAX_VISIBLE_BOOKS + 1
    local last = math.min(#self.books, first + MAX_VISIBLE_BOOKS - 1)
    for index = first, last do
        table.insert(list, self:makeBookCard(self.books[index]))
        if index < last then table.insert(list, VerticalSpan:new{ width = Screen:scaleBySize(2) }) end
    end
    return list
end

function LibraryDashboard:makePageNavigation()
    if self.page_count <= 1 then return nil end
    local gap = Screen:scaleBySize(8)
    local side_width = Screen:scaleBySize(100)
    local center_width = self.content_width - 2 * side_width - 2 * gap
    return HorizontalGroup:new{
        align = "center",
        Button:new{
            text = _("Previous"),
            width = side_width,
            height = Screen:scaleBySize(36),
            radius = Size.radius.button,
            enabled = self.page > 1,
            text_font_size = 15,
            callback = function()
                self.plugin.library_page = self.page - 1
                self:refreshDashboard()
            end,
        },
        HorizontalSpan:new{ width = gap },
        CenterContainer:new{
            dimen = Geom:new{ w = center_width, h = Screen:scaleBySize(36) },
            TextWidget:new{
                text = string.format(_("Page %d of %d"), self.page, self.page_count),
                face = Font:getFace("smallinfofont"),
                bold = true,
            },
        },
        HorizontalSpan:new{ width = gap },
        Button:new{
            text = _("Next"),
            width = side_width,
            height = Screen:scaleBySize(36),
            radius = Size.radius.button,
            enabled = self.page < self.page_count,
            text_font_size = 15,
            callback = function()
                self.plugin.library_page = self.page + 1
                self:refreshDashboard()
            end,
        },
    }
end

function LibraryDashboard:buildContent()
    local content = VerticalGroup:new{ align = "left" }
    local in_subfolder = self.current_dir ~= self.library_root
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(12) })
    table.insert(content, HorizontalGroup:new{
        HorizontalSpan:new{ width = self.outer_padding },
        self:makeHeaderActions(),
    })
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(2) })
    table.insert(content, TitleBar:new{
        width = self.screen_width,
        align = "left",
        title = _("Library"),
        subtitle = self:subtitleText(),
        with_bottom_line = true,
        left_icon = in_subfolder and "chevron.left" or nil,
        left_icon_tap_callback = function()
            self:navigateTo(FFIUtil.dirname(self.current_dir))
        end,
        show_parent = self,
    })
    table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(8) })

    local inner = VerticalGroup:new{ align = "left" }
    table.insert(inner, self:sectionLabel(_("BOOKS")))
    table.insert(inner, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(inner, self:makeBookList())
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = self.screen_width, h = inner:getSize().h },
        inner,
    })

    local dimen = Geom:new{ x = 0, y = 0, w = self.screen_width, h = self.screen_height }
    local layers = {
        dimen = dimen,
        allow_mirroring = false,
        content,
    }
    local page_navigation = self:makePageNavigation()
    if page_navigation then
        table.insert(layers, BottomContainer:new{
            dimen = dimen,
            VerticalGroup:new{
                align = "center",
                page_navigation,
                VerticalSpan:new{ width = Screen:scaleBySize(2) },
            },
        })
    end
    return OverlapGroup:new(layers)
end

function LibraryDashboard:onSwipeDashboard(_, ges_ev)
    if ges_ev.direction == "south" then
        self.plugin:showReaderChrome(true, false)
        return true
    end
    return false
end

function LibraryDashboard:onClose()
    if self.current_dir ~= self.library_root then
        self:navigateTo(FFIUtil.dirname(self.current_dir))
    end
    return true
end

function LibraryDashboard:onCloseWidget()
    if self.plugin and self.plugin.dashboard == self then
        self.plugin.dashboard = nil
    end
end

local LibraryPlugin = WidgetContainer:extend{
    name = "library",
    is_doc_only = false,
}

function LibraryPlugin:init()
    self.ui.menu:registerToMainMenu(self)

    if not self.ui.document and G_reader_settings:nilOrTrue("minimal_library_auto_open") then
        UIManager:nextTick(function()
            if self.ui and not self.ui.document and not self.dashboard then
                self:showDashboard()
            end
        end)
    end
end

function LibraryPlugin:getLibraryRoot()
    local root = G_reader_settings:readSetting("minimal_library_root")
        or G_reader_settings:readSetting("home_dir")
        or Device.home_dir
        or "."
    root = normalizePath(root)
    if not root or lfs.attributes(root, "mode") ~= "directory" then
        root = normalizePath(Device.home_dir) or "."
    end
    return root
end

function LibraryPlugin:setLibraryRoot(path)
    path = normalizePath(path)
    if not path or lfs.attributes(path, "mode") ~= "directory" then return false end
    G_reader_settings:saveSetting("minimal_library_root", path)
    self.library_current_dir = path
    self.library_page = 1
    return true
end

function LibraryPlugin:getDirectoryChooserRoot()
    local library_root = self:getLibraryRoot()
    if pathIsInside(library_root, "/mnt/us") and lfs.attributes("/mnt/us", "mode") == "directory" then
        return "/mnt/us"
    end
    local data_dir = normalizePath(DataStorage:getDataDir())
    if data_dir and pathIsInside(library_root, data_dir) then
        return data_dir
    end
    return "/"
end

function LibraryPlugin:showDashboard()
    if self.dashboard then
        return
    end

    self.dashboard = LibraryDashboard:new{
        plugin = self,
        ui = self.ui,
    }
    UIManager:show(self.dashboard)
end

function LibraryPlugin:showPageSlider()
    if not self.ui or not self.ui.document then
        return
    end

    local slider = PageSlider:new{
        ui = self.ui,
    }
    UIManager:show(slider)
    return slider
end

function LibraryPlugin:closeReaderChrome()
    if self.reader_chrome then
        local chrome = self.reader_chrome
        self.reader_chrome = nil
        UIManager:close(chrome)
    end
end

function LibraryPlugin:closeDashboard()
    if self.dashboard then
        local dashboard = self.dashboard
        self.dashboard = nil
        UIManager:close(dashboard)
    end
end

function LibraryPlugin:closeOwnedWidgets()
    self:closeReaderChrome()
    self:closeDashboard()
end

function LibraryPlugin:showReaderChrome(show_top, show_bottom, bottom_mode)
    if not self.ui or (show_bottom and not self.ui.document) then
        return
    end

    if self.reader_chrome then
        show_top = show_top or self.reader_chrome.show_top
        show_bottom = show_bottom or self.reader_chrome.show_bottom
        bottom_mode = bottom_mode or self.reader_chrome.bottom_mode
        self:closeReaderChrome()
    end

    self.reader_chrome = MinimalReaderChrome:new{
        plugin = self,
        ui = self.ui,
        show_top = show_top,
        show_bottom = show_bottom,
        bottom_mode = bottom_mode or "slider",
    }
    UIManager:show(self.reader_chrome)
end

function LibraryPlugin:openLibraryFromReader()
    if self.ui and self.ui.document then
        local reader_ui = self.ui
        local current_file = reader_ui.document.file
        reader_ui:onClose()
        reader_ui:showFileManager(current_file)
        -- FileManager creates a fresh Library plugin instance. Put its
        -- dashboard on top immediately, before UIManager gets a paint cycle.
        local FileManager = require("apps/filemanager/filemanager")
        local file_manager_plugin = FileManager.instance and FileManager.instance.library
        if file_manager_plugin then
            file_manager_plugin:showDashboard()
        end
    elseif self.dashboard then
        UIManager:setDirty(self.dashboard, "ui")
    else
        self:showDashboard()
    end
end

function LibraryPlugin:showContextSearch()
    if self.ui and self.ui.document then
        self:showReaderSearch()
    elseif self.ui and self.ui.filesearcher then
        self.ui.filesearcher:onShowFileSearch()
    end
end

function LibraryPlugin:showDictionaryLookup()
    if self.ui and self.ui.dictionary then
        self.ui.dictionary:onShowDictionaryLookup()
    end
end

function LibraryPlugin:showVocabularyBuilder()
    UIManager:broadcastEvent(Event:new("ShowVocabBuilder"))
end

function LibraryPlugin:showTableOfContents()
    if self.ui and self.ui.toc then
        self.ui.toc:onShowToc()
    end
end

function LibraryPlugin:showReaderSearch()
    if self.ui and self.ui.search then
        self.ui.search:onShowFulltextSearchInput()
    end
end

function LibraryPlugin:showBookmarks()
    if self.ui and self.ui.bookmark then
        self.ui.bookmark:onShowBookmark()
    end
end

function LibraryPlugin:toggleWifi()
    if not Device:hasWifiToggle() then
        UIManager:show(InfoMessage:new{
            text = _("Wi-Fi is managed by the host on this device."),
        })
        return
    end
    UIManager:broadcastEvent(Event:new("ToggleWifi"))
end

function LibraryPlugin:showBrightnessControl()
    if not Device:hasFrontlight() then
        UIManager:show(InfoMessage:new{
            text = _("Brightness control is not available on this device."),
        })
        return
    end
    UIManager:broadcastEvent(Event:new("ShowFlDialog"))
end

function LibraryPlugin:showWarmthControl()
    if not Device:hasNaturalLight() then
        UIManager:show(InfoMessage:new{
            text = _("Warmth control is not available on this device."),
        })
        return
    end
    UIManager:broadcastEvent(Event:new("ShowFlDialog"))
end

function LibraryPlugin:showLightControl()
    if not Device:hasFrontlight() then
        UIManager:show(InfoMessage:new{
            text = _("Front-light controls are not available on this device."),
        })
        return
    end
    -- KOReader's native front-light dialog combines brightness and warmth
    -- when the device supports natural light.
    UIManager:broadcastEvent(Event:new("ShowFlDialog"))
end

function LibraryPlugin:toggleNightMode()
    UIManager:broadcastEvent(Event:new("ToggleNightMode"))
end

function LibraryPlugin:confirmExitToKindle()
    UIManager:show(ConfirmBox:new{
        text = _("Exit HongReader and return to the Kindle Home screen?"),
        ok_text = _("Exit to Kindle"),
        ok_callback = function()
            self:exitToKindle()
        end,
    })
end

function LibraryPlugin:closeKOReader(callback)
    -- The dashboard is a top-level UIManager widget. Leaving it open while
    -- closing FileManager keeps the window stack non-empty, so KOReader never
    -- reaches its launcher cleanup and the Kindle Home screen cannot resume.
    self:closeOwnedWidgets()

    local function finishClose()
        if callback then callback() end
        -- Do not rely solely on UIManager's implicit empty-stack quit: other
        -- transient widgets may still be closing in this tick.
        UIManager:quit()
    end

    -- The menu owns KOReader's context-specific close path. In Reader it saves
    -- the document first; in FileManager it tears down the dashboard and then
    -- lets the Kindle launcher resume the stock UI.
    if self.ui and self.ui.menu and self.ui.menu.exitOrRestart then
        self.ui.menu:exitOrRestart(finishClose, true)
        return
    end
    if self.ui and self.ui.onClose then
        self.ui:onClose()
    end
    finishClose()
end

function LibraryPlugin:exitToKindle()
    self:closeKOReader()
end

function LibraryPlugin:runKindleSystemAction(action_name, command)
    -- Spawn the delayed action before KOReader exits. KUAL may tear down its
    -- original process tree when koreader.sh returns, so use a new session when
    -- available. Keep a persistent log for device-side diagnosis if a firmware
    -- rejects a command.
    local log_path = DataStorage:getDataDir() .. "/hongreader-power.log"
    local action = table.concat({
        "echo \"$(date '+%Y-%m-%d %H:%M:%S') HongReader: starting " .. action_name .. "\"",
        "sleep 4",
        "sync",
        command,
        "status=$?",
        "echo \"$(date '+%Y-%m-%d %H:%M:%S') HongReader: " .. action_name .. " returned $status\"",
        "exit $status",
    }, "; ")
    local quoted_action = shellQuote(action)
    local detached = string.format(
        "(if command -v setsid >/dev/null 2>&1; then setsid sh -c %s; " ..
        "else sh -c %s; fi) </dev/null >>%s 2>&1 &",
        quoted_action,
        quoted_action,
        shellQuote(log_path)
    )
    local result = os.execute(detached)
    if result ~= 0 and result ~= true then
        UIManager:show(InfoMessage:new{
            text = _("The system action could not be started."),
            icon = "notice-warning",
        })
        return
    end
    self:closeKOReader()
end

function LibraryPlugin:requestRestart()
    if not Device:isKindle() then
        UIManager:askForReboot()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Restart this Kindle now?"),
        ok_text = _("Restart"),
        ok_callback = function()
            self:runKindleSystemAction(
                "restart",
                "if [ -x /sbin/reboot ]; then /sbin/reboot; fi; " ..
                "if command -v reboot >/dev/null 2>&1; then reboot; fi; " ..
                "if command -v busybox >/dev/null 2>&1; then busybox reboot; fi; exit 127"
            )
        end,
    })
end

function LibraryPlugin:requestPowerOff()
    if not Device:isKindle() then
        UIManager:askForPowerOff()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Power off this Kindle now?"),
        ok_text = _("Power off"),
        ok_callback = function()
            self:runKindleSystemAction(
                "power off",
                "if [ -x /sbin/poweroff ]; then /sbin/poweroff; fi; " ..
                "if command -v poweroff >/dev/null 2>&1; then poweroff; fi; " ..
                "if command -v busybox >/dev/null 2>&1; then busybox poweroff; fi; " ..
                "if command -v halt >/dev/null 2>&1; then halt -p; fi; exit 127"
            )
        end,
    })
end

function LibraryPlugin:showPowerMenu()
    local power_menu
    local function closeThen(callback)
        UIManager:close(power_menu)
        UIManager:nextTick(callback)
    end

    power_menu = Menu:new{
        title = _("Power"),
        subtitle = _("Device and session"),
        item_table = {
            {
                text = _("Sleep"),
                enabled_func = function() return Device:canSuspend() end,
                callback = function()
                    closeThen(function() UIManager:suspend() end)
                end,
            },
            {
                text = _("Restart"),
                enabled_func = function()
                    return Device:isKindle() or Device:canReboot()
                end,
                callback = function()
                    closeThen(function() self:requestRestart() end)
                end,
            },
            {
                text = _("Power off"),
                enabled_func = function()
                    return Device:isKindle() or Device:canPowerOff()
                end,
                callback = function()
                    closeThen(function() self:requestPowerOff() end)
                end,
            },
            {
                text = _("Exit to Kindle"),
                callback = function()
                    closeThen(function() self:confirmExitToKindle() end)
                end,
            },
        },
        items_per_page = 4,
        width = math.floor(Screen:getWidth() * 0.76),
        height = math.floor(Screen:getHeight() * 0.52),
    }
    UIManager:show(power_menu)
end

function LibraryPlugin:showOriginalTopMenu()
    if self.original_show_menu and self.ui and self.ui.menu then
        self.original_show_menu(self.ui.menu)
    end
end

function LibraryPlugin:showOriginalConfigMenu()
    if self.original_show_config_menu and self.ui and self.ui.config then
        self.original_show_config_menu(self.ui.config)
    end
end

function LibraryPlugin:showFontSettings()
    if self.ui and self.ui.config then
        -- The first native configuration panel contains typography controls.
        self.ui.config.last_panel_index = 1
    end
    self:showOriginalConfigMenu()
end

function LibraryPlugin:patchReaderChrome()
    if self.original_show_menu or not self.ui.menu or not self.ui.config then
        return
    end

    local plugin = self
    self.original_show_menu = self.ui.menu.onShowMenu
    self.original_close_menu = self.ui.menu.onCloseReaderMenu
    self.original_show_config_menu = self.ui.config.onShowConfigMenu
    self.original_close_config_menu = self.ui.config.onCloseConfigMenu

    self.ui.menu.onShowMenu = function(reader_menu, tab_index, do_not_show)
        if do_not_show then
            return plugin.original_show_menu(reader_menu, tab_index, do_not_show)
        end
        plugin:showReaderChrome(true, false)
        return true
    end
    self.ui.menu.onCloseReaderMenu = function(reader_menu)
        plugin:closeReaderChrome()
        if reader_menu.menu_container then
            return plugin.original_close_menu(reader_menu)
        end
        return true
    end
    self.ui.config.onShowConfigMenu = function()
        plugin:showReaderChrome(false, true)
        return true
    end
    self.ui.config.onCloseConfigMenu = function(reader_config)
        plugin:closeReaderChrome()
        if reader_config.config_dialog then
            return plugin.original_close_config_menu(reader_config)
        end
        return true
    end
end

function LibraryPlugin:restoreReaderChromeHooks()
    self:closeReaderChrome()
    if self.original_show_menu and self.ui and self.ui.menu then
        self.ui.menu.onShowMenu = self.original_show_menu
        self.ui.menu.onCloseReaderMenu = self.original_close_menu
    end
    if self.original_show_config_menu and self.ui and self.ui.config then
        self.ui.config.onShowConfigMenu = self.original_show_config_menu
        self.ui.config.onCloseConfigMenu = self.original_close_config_menu
    end
    self.original_show_menu = nil
    self.original_close_menu = nil
    self.original_show_config_menu = nil
    self.original_close_config_menu = nil
end

function LibraryPlugin:applyFooterPreset(preset)
    local footer = self.ui and self.ui.view and self.ui.view.footer
    if not footer or not preset or not preset.footer then
        return
    end

    footer:loadPreset(preset)
    footer.height = Screen:scaleBySize(footer.settings.container_height)
    footer.bottom_padding = Screen:scaleBySize(footer.settings.container_bottom_padding)
    footer:updateFooterContainer()
    footer:resetLayout(true)
    footer:refreshFooter(true, true)
end

function LibraryPlugin:applyMinimalFooter()
    local footer = self.ui and self.ui.view and self.ui.view.footer
    if not footer then
        return
    end

    if not G_reader_settings:has("minimal_library_footer_backup") then
        G_reader_settings:saveSetting("minimal_library_footer_backup", footer:buildPreset())
    end

    local preset = footer:buildPreset()
    local settings = util.tableDeepCopy(preset.footer)
    for _, name in ipairs({
        "pages_left_book",
        "time",
        "battery",
        "book_time_to_read",
        "chapter_time_to_read",
        "frontlight",
        "frontlight_warmth",
        "mem_usage",
        "wifi_status",
        "page_turning_inverted",
        "book_author",
        "book_title",
        "book_chapter",
        "bookmark_count",
        "chapter_progress",
        "custom_text",
        "additional_content",
        "dynamic_filler",
        "dynamic_filler2",
    }) do
        settings[name] = false
    end
    settings.disabled = false
    settings.disable_progress_bar = false
    settings.all_at_once = false
    settings.page_progress = true
    settings.pages_left = true
    settings.percentage = true
    settings.progress_style_thin = true
    settings.progress_style_thin_height = 2
    settings.progress_style_thick_height = 6
    settings.progress_bar_position = "alongside"
    settings.progress_margin_width = 12
    settings.progress_bar_min_width_pct = 74
    settings.container_height = 20
    settings.container_bottom_padding = 2
    settings.text_font_size = 13
    settings.text_font_bold = false
    settings.item_prefix = "compact_items"
    settings.items_separator = "none"
    settings.progress_pct_format = "0"
    settings.toc_markers = true
    settings.toc_markers_width = 2
    settings.chapter_progress_bar = false
    settings.initial_marker = false
    settings.bottom_horizontal_separator = false
    settings.align = "right"

    preset.footer = settings
    preset.reader_footer_mode = footer.mode_list.percentage or footer.mode_list.page_progress or 1
    self:applyFooterPreset(preset)
    self:installFooterCycle()
end

function LibraryPlugin:installFooterCycle()
    local footer = self.ui and self.ui.view and self.ui.view.footer
    if not footer or self.footer_cycle_target == footer then return end

    self.footer_cycle_target = footer
    self.original_footer_toggle_mode = footer.onToggleFooterMode
    footer.onToggleFooterMode = function(current_footer)
        local modes = {
            current_footer.mode_list.percentage,
            current_footer.mode_list.page_progress,
            current_footer.mode_list.pages_left,
        }
        local current_index = 1
        for index, mode in ipairs(modes) do
            if current_footer.mode == mode then
                current_index = index
                break
            end
        end
        local next_mode = modes[current_index % #modes + 1]
        current_footer:applyFooterMode(next_mode)
        G_reader_settings:saveSetting("reader_footer_mode", next_mode)
        current_footer:onUpdateFooter(true)
        current_footer:rescheduleFooterAutoRefreshIfNeeded()
        return true
    end
end

function LibraryPlugin:restoreFooterCycle()
    if self.footer_cycle_target and self.original_footer_toggle_mode then
        self.footer_cycle_target.onToggleFooterMode = self.original_footer_toggle_mode
    end
    self.footer_cycle_target = nil
    self.original_footer_toggle_mode = nil
end

function LibraryPlugin:applyAltStatusBar()
    -- CRE's top status bar uses 0 for enabled and 1 for disabled.
    G_reader_settings:saveSetting("copt_status_line", 0)
    -- CRE interprets this value as raw framebuffer pixels, not a
    -- DPI-independent font size.  Forty pixels is comfortable on a 300-DPI
    -- Paperwhite, but is physically twice as tall in our 150-DPI emulator.
    -- Scale from the Paperwhite value so the preview and device have the same
    -- apparent header height.
    local screen_dpi = Screen.getDPI and Screen:getDPI() or 300
    local header_font_size = math.floor(40 * screen_dpi / 300 + 0.5)
    header_font_size = math.max(20, math.min(40, header_font_size))
    local header_settings = {
        cre_header_title = 1,
        -- CRE alternates title and author when both do not fit. Keep the title
        -- visible on every page instead of allowing the author to replace it.
        cre_header_author = 0,
        cre_header_clock = 1,
        cre_header_page_number = 1,
        cre_header_page_count = 1,
        cre_header_reading_percent = 1,
        cre_header_battery = 0,
        cre_header_battery_percent = 0,
        cre_header_chapter_marks = 0,
        cre_header_status_font_size = header_font_size,
    }
    for name, value in pairs(header_settings) do
        G_reader_settings:saveSetting(name, value)
    end

    local listener = self.ui and self.ui.crelistener
    if not listener then return end

    listener.title = 1
    listener.author = 0
    listener.clock = 1
    listener.page_number = 1
    listener.page_count = 1
    listener.reading_percent = 1
    listener.battery = 0
    listener.battery_percent = 0
    listener.chapter_marks = 0
    local document = self.ui.document
    if document and document.configurable then
        document.configurable.status_line = 0
    end
    if document and document.setAltDocumentProp then
        local props = self.ui.doc_props or {}
        local title = props.display_title or props.title
        local author = props.authors or props.author
        if title and title ~= "" then
            local identity = title
            if author and author ~= "" then
                identity = identity .. " · " .. author
            end
            document:setAltDocumentProp("title", identity)
        end
    end
    if document and document._document then
        document._document:setIntProperty("window.status.title", 1)
        document._document:setIntProperty("window.status.author", 0)
        document._document:setIntProperty("window.status.clock", 1)
        document._document:setIntProperty("window.status.pos.page.number", 1)
        document._document:setIntProperty("window.status.pos.page.count", 1)
        document._document:setIntProperty("window.status.pos.percent", 1)
        document._document:setIntProperty("window.status.battery", 0)
        document._document:setIntProperty("window.status.battery.percent", 0)
        document._document:setIntProperty("crengine.page.header.chapter.marks", 0)
        document._document:setIntProperty("crengine.page.header.font.size", header_font_size)
    end
    self:installHeaderBatteryIndicator()
    self.ui:handleEvent(Event:new("SetStatusLine", 0))
    listener:onUpdateHeader()
end

function LibraryPlugin:getHeaderBatteryText()
    if not Device:hasBattery() then return "" end

    local powerd = Device:getPowerDevice()
    if not powerd or not powerd.getCapacity then return "" end

    local level = powerd:getCapacity()
    if type(level) ~= "number" then return "" end

    if Device:hasAuxBattery() and powerd.isAuxBatteryConnected
            and powerd:isAuxBatteryConnected() and powerd.getAuxCapacity then
        level = level + powerd:getAuxCapacity()
    end

    return string.format("⚡ %d%%", level)
end

function LibraryPlugin:installHeaderBatteryIndicator()
    local listener = self.ui and self.ui.crelistener
    if not listener or not listener.addAdditionalHeaderContent then return end

    self:removeHeaderBatteryIndicator()
    self.header_battery_content_func = function()
        return self:getHeaderBatteryText()
    end
    listener:addAdditionalHeaderContent(self.header_battery_content_func)
end

function LibraryPlugin:removeHeaderBatteryIndicator()
    local listener = self.ui and self.ui.crelistener
    if listener and self.header_battery_content_func
            and listener.removeAdditionalHeaderContent then
        listener:removeAdditionalHeaderContent(self.header_battery_content_func)
    end
    self.header_battery_content_func = nil
end

function LibraryPlugin:installHeaderProgressMask()
    local view = self.ui and self.ui.view
    if not view or not view.registerViewModule then return end

    self:removeHeaderProgressMask()
    self.header_progress_mask = HeaderProgressMask:new{}
    view:registerViewModule("library_header_progress_mask", self.header_progress_mask)
end

function LibraryPlugin:removeHeaderProgressMask()
    local view = self.ui and self.ui.view
    if view and view.view_modules
            and view.view_modules.library_header_progress_mask == self.header_progress_mask then
        view.view_modules.library_header_progress_mask = nil
    end
    self.header_progress_mask = nil
end

function LibraryPlugin:restoreFooter()
    self:restoreFooterCycle()
    local backup = G_reader_settings:readSetting("minimal_library_footer_backup")
    if backup then
        self:applyFooterPreset(backup)
        G_reader_settings:delSetting("minimal_library_footer_backup")
    end
end

function LibraryPlugin:isReaderStyleEnabled()
    return G_reader_settings:nilOrTrue("minimal_library_reader_style")
end

function LibraryPlugin:applyReaderStyle()
    if not self.ui or not self.ui.document then
        return
    end
    self:applyMinimalFooter()
    self:applyAltStatusBar()
    self:installHeaderProgressMask()
    self:patchReaderChrome()
end

function LibraryPlugin:restoreReaderStyle()
    self:restoreReaderChromeHooks()
    self:removeHeaderBatteryIndicator()
    self:removeHeaderProgressMask()
    self:restoreFooter()
end

function LibraryPlugin:installGlobalFontSize()
    local reader_font = self.ui and self.ui.font
    if not reader_font or not reader_font.onSetFontSize
            or self.global_font_target == reader_font then
        return
    end

    self.global_font_target = reader_font
    self.original_set_font_size = reader_font.onSetFontSize
    local plugin = self
    reader_font.onSetFontSize = function(font_module, size)
        local result = plugin.original_set_font_size(font_module, size)
        local applied_size = font_module.configurable and font_module.configurable.font_size or size
        G_reader_settings:saveSetting("minimal_library_global_font_size", applied_size)
        -- Also use KOReader's native default key so books opened without this
        -- plugin inherit the same typography.
        G_reader_settings:saveSetting("copt_font_size", applied_size)
        return result
    end

    local saved_size = tonumber(G_reader_settings:readSetting("minimal_library_global_font_size"))
    if saved_size and reader_font.configurable and self.ui.document then
        saved_size = clamp(saved_size, 12, 255)
        if reader_font.configurable.font_size ~= saved_size then
            reader_font.configurable.font_size = saved_size
            self.ui.document:setFontSize(Screen:scaleBySize(saved_size))
            self.ui:handleEvent(Event:new("UpdatePos"))
        end
    end
end

function LibraryPlugin:restoreGlobalFontSizeHook()
    if self.global_font_target and self.original_set_font_size then
        self.global_font_target.onSetFontSize = self.original_set_font_size
    end
    self.global_font_target = nil
    self.original_set_font_size = nil
end

function LibraryPlugin:onReaderReady()
    self:installGlobalFontSize()
    if self:isReaderStyleEnabled() then
        self:applyReaderStyle()
    end
end

function LibraryPlugin:onCloseDocument()
    self:restoreGlobalFontSizeHook()
    self:restoreReaderChromeHooks()
    self:removeHeaderBatteryIndicator()
    self:removeHeaderProgressMask()
end

function LibraryPlugin:addToMainMenu(menu_items)
    menu_items.minimal_library = {
        text = _("Library"),
        sorting_hint = "more_tools",
        callback = function()
            self:showDashboard()
        end,
    }
    menu_items.page_slider = {
        text = _("Page slider"),
        sorting_hint = "more_tools",
        enabled_func = function()
            return self.ui and self.ui.document ~= nil
        end,
        callback = function()
            self:showPageSlider()
        end,
    }
    menu_items.minimal_reader_style = {
        text = _("Clean reader interface"),
        sorting_hint = "more_tools",
        enabled_func = function()
            return self.ui and self.ui.document ~= nil
        end,
        checked_func = function()
            return self:isReaderStyleEnabled()
        end,
        callback = function()
            local enable = not self:isReaderStyleEnabled()
            G_reader_settings:saveSetting("minimal_library_reader_style", enable)
            if enable then
                self:applyReaderStyle()
            else
                self:restoreReaderStyle()
            end
        end,
    }
end

return LibraryPlugin
