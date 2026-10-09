--!strict

const CoreGui = game:GetService("CoreGui")

export type Tone = "Ok" | "Working" | "Attention" | "Off"

export type Status = {
	tone: Tone,
	text: string,
}

export type Overlay = {
	Show: (status: Status) -> (),
	SetVisible: (visible: boolean) -> (),
	SetHover: (ReadHover: () -> string) -> (),
	AskToken: (prompt: string, Submit: (token: string) -> string?, Dismissed: (() -> ())?) -> (),
	CloseTokenBox: () -> (),
	Destroy: () -> (),
}

const TONE_COLORS: { [Tone]: Color3 } = {
	Ok = Color3.fromRGB(80, 200, 120),
	Working = Color3.fromRGB(240, 180, 60),
	Attention = Color3.fromRGB(235, 80, 70),
	Off = Color3.fromRGB(140, 140, 140),
}
const PANEL_COLOR = Color3.fromRGB(24, 24, 24)
const TEXT_COLOR = Color3.fromRGB(235, 235, 235)
const DETAIL_COLOR = Color3.fromRGB(175, 175, 175)
const PANEL_TRANSPARENCY = 0.15
const FONT = Font.fromEnum(Enum.Font.BuilderSans)
const TEXT_SIZE = 14
const DETAIL_TEXT_SIZE = 13
const MARGIN = 12
const PADDING = 8
const GAP = 6
const DOT_SIZE = 8
const MAX_WIDTH = 460
const MAX_CHANGE_LINES = 12
const HOVER_PLACEHOLDER = "Looking up commits..."
const TOKEN_PLACEHOLDER = "github_pat_..."
const TOKEN_CHECKING = "Checking the token with GitHub..."
const TOKEN_BOX_HEIGHT = 26
const BUTTON_COLOR = Color3.fromRGB(60, 120, 200)
const BOX_COLOR = Color3.fromRGB(0, 0, 0)

local function Panel(name: string, className: "Frame" | "TextButton"): GuiObject
	const panel = Instance.new(className) :: GuiObject
	panel.Name = name
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = PANEL_TRANSPARENCY
	panel.BorderSizePixel = 0
	panel.AutomaticSize = Enum.AutomaticSize.XY
	panel.Size = UDim2.fromOffset(0, 0)

	const corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, PADDING)
	corner.Parent = panel

	const padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, PADDING / 2)
	padding.PaddingBottom = UDim.new(0, PADDING / 2)
	padding.PaddingLeft = UDim.new(0, PADDING)
	padding.PaddingRight = UDim.new(0, PADDING)
	padding.Parent = panel
	return panel
end

local function Label(name: string, size: number, color: Color3, wrapped: boolean, maxWidth: number): TextLabel
	const label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.FontFace = FONT
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = wrapped
	label.TextTruncate = if wrapped then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.fromOffset(0, 0)

	const limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(maxWidth, math.huge)
	limit.Parent = label
	return label
end

local function FirstLines(text: string, count: number): string
	const lines = string.split(text, "\n")
	if #lines <= count then
		return text
	end
	const shown = table.move(lines, 1, count, 1, {})
	table.insert(shown, `... and {#lines - count} more`)
	return table.concat(shown, "\n")
end

local function TokenBox(): TextBox
	const box = Instance.new("TextBox")
	box.Name = "Token"
	box.BackgroundColor3 = BOX_COLOR
	box.BackgroundTransparency = PANEL_TRANSPARENCY
	box.BorderSizePixel = 0
	box.FontFace = FONT
	box.TextSize = TEXT_SIZE
	box.TextColor3 = TEXT_COLOR
	box.PlaceholderText = TOKEN_PLACEHOLDER
	box.PlaceholderColor3 = DETAIL_COLOR
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextTruncate = Enum.TextTruncate.AtEnd
	box.ClearTextOnFocus = false
	box.Text = ""
	box.Size = UDim2.fromOffset(MAX_WIDTH - 2 * PADDING, TOKEN_BOX_HEIGHT)
	box.LayoutOrder = 2

	const padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, PADDING / 2)
	padding.PaddingRight = UDim.new(0, PADDING / 2)
	padding.Parent = box
	return box
end

local function TokenButton(name: string, order: number): TextButton
	const button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundColor3 = BUTTON_COLOR
	button.BorderSizePixel = 0
	button.FontFace = FONT
	button.TextSize = TEXT_SIZE
	button.TextColor3 = TEXT_COLOR
	button.Text = name
	button.AutomaticSize = Enum.AutomaticSize.X
	button.Size = UDim2.fromOffset(0, TOKEN_BOX_HEIGHT)
	button.LayoutOrder = order

	const corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, PADDING / 2)
	corner.Parent = button
	const padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, PADDING * 2)
	padding.PaddingRight = UDim.new(0, PADDING * 2)
	padding.Parent = button
	return button
end

local function ButtonRow(): Frame
	const row = Instance.new("Frame")
	row.Name = "Buttons"
	row.BackgroundTransparency = 1
	row.AutomaticSize = Enum.AutomaticSize.XY
	row.Size = UDim2.fromOffset(0, 0)
	row.LayoutOrder = 3

	const layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, GAP)
	layout.Parent = row
	return row
end

const Overlay = {}

--- Draws this Studio's sync status as a pill in the bottom-left of the viewport. Clicking the pill
--- shows the full status and the last change list, which ReadChanges returns. Hovering it shows what
--- the function given to SetHover returns, which may yield. AskToken opens a box above the pill for
--- pasting a GitHub token; Submit returns why the token was refused, or nil once it is accepted.
--- Its Close button closes it without a token and calls Dismissed. CloseTokenBox closes it from code.
function Overlay.New(label: string, ReadChanges: () -> string?): Overlay
	const gui = Instance.new("ScreenGui")
	gui.Name = "StudioSyncStatus"
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	const column = Instance.new("Frame")
	column.Name = "Column"
	column.BackgroundTransparency = 1
	column.AnchorPoint = Vector2.new(0, 1)
	column.Position = UDim2.new(0, MARGIN, 1, -MARGIN)
	column.AutomaticSize = Enum.AutomaticSize.XY
	column.Size = UDim2.fromOffset(0, 0)
	column.Parent = gui

	const columnLayout = Instance.new("UIListLayout")
	columnLayout.FillDirection = Enum.FillDirection.Vertical
	columnLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	columnLayout.SortOrder = Enum.SortOrder.LayoutOrder
	columnLayout.Padding = UDim.new(0, GAP)
	columnLayout.Parent = column

	const details = Panel("Details", "Frame")
	details.LayoutOrder = 1
	details.Visible = false
	details.Parent = column
	const detailText = Label("Text", DETAIL_TEXT_SIZE, DETAIL_COLOR, true, MAX_WIDTH - 2 * PADDING)
	detailText.Parent = details

	const hover = Panel("Hover", "Frame")
	hover.LayoutOrder = 2
	hover.Visible = false
	hover.Parent = column
	const hoverText = Label("Text", DETAIL_TEXT_SIZE, TEXT_COLOR, true, MAX_WIDTH - 2 * PADDING)
	hoverText.Parent = hover

	const tokenPanel = Panel("TokenPanel", "Frame")
	tokenPanel.LayoutOrder = 3
	tokenPanel.Visible = false
	tokenPanel.Parent = column
	const tokenLayout = Instance.new("UIListLayout")
	tokenLayout.FillDirection = Enum.FillDirection.Vertical
	tokenLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tokenLayout.Padding = UDim.new(0, GAP)
	tokenLayout.Parent = tokenPanel
	const tokenPrompt = Label("Prompt", DETAIL_TEXT_SIZE, TEXT_COLOR, true, MAX_WIDTH - 2 * PADDING)
	tokenPrompt.LayoutOrder = 1
	tokenPrompt.Parent = tokenPanel
	const tokenBox = TokenBox()
	tokenBox.Parent = tokenPanel
	const buttonRow = ButtonRow()
	buttonRow.Parent = tokenPanel
	const saveButton = TokenButton("Save", 1)
	saveButton.Parent = buttonRow
	const closeButton = TokenButton("Close", 2)
	closeButton.Parent = buttonRow
	const tokenMessage = Label("Message", DETAIL_TEXT_SIZE, DETAIL_COLOR, true, MAX_WIDTH - 2 * PADDING)
	tokenMessage.LayoutOrder = 4
	tokenMessage.Visible = false
	tokenMessage.Parent = tokenPanel

	const pill = Panel("Pill", "TextButton") :: TextButton
	pill.LayoutOrder = 4
	pill.AutoButtonColor = false
	pill.Text = ""
	pill.Parent = column

	const pillLayout = Instance.new("UIListLayout")
	pillLayout.FillDirection = Enum.FillDirection.Horizontal
	pillLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	pillLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pillLayout.Padding = UDim.new(0, GAP)
	pillLayout.Parent = pill

	const dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.BorderSizePixel = 0
	dot.Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE)
	dot.LayoutOrder = 1
	dot.Parent = pill
	const dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(0.5, 0)
	dotCorner.Parent = dot

	const pillText = Label("Text", TEXT_SIZE, TEXT_COLOR, false, MAX_WIDTH - 2 * PADDING - DOT_SIZE - GAP)
	pillText.LayoutOrder = 2
	pillText.Parent = pill

	local current: Status = { tone = "Working", text = "Starting" }

	local function RefreshDetails()
		if not details.Visible then
			return
		end
		const changes = ReadChanges()
		detailText.Text = if changes and changes ~= ""
			then `{current.text}\n\nLast changes:\n{FirstLines(changes, MAX_CHANGE_LINES)}`
			else current.text
	end

	local ReadHover: (() -> string)? = nil
	local hovering = false
	local hoverGeneration = 0

	local function RefreshHover()
		if not hovering or not ReadHover then
			return
		end
		hoverGeneration += 1
		const generation = hoverGeneration
		const text = ReadHover()
		if hovering and generation == hoverGeneration then
			hoverText.Text = text
			hover.Visible = true
		end
	end

	local function ShowHover()
		hovering = true
		if ReadHover and not hover.Visible then
			hoverText.Text = HOVER_PLACEHOLDER
			hover.Visible = true
		end
		RefreshHover()
	end

	local function HideHover()
		hovering = false
		hover.Visible = false
	end

	local function Show(status: Status)
		current = status
		dot.BackgroundColor3 = TONE_COLORS[status.tone]
		pillText.Text = `{label}: {status.text}`
		RefreshDetails()
		if hovering then
			task.spawn(RefreshHover)
		end
	end

	local SubmitToken: ((token: string) -> string?)? = nil
	local TokenDismissed: (() -> ())? = nil
	local checkingToken = false
	local shown = true

	local function CloseTokenBox()
		SubmitToken = nil
		TokenDismissed = nil
		tokenBox.Text = ""
		tokenMessage.Visible = false
		tokenPanel.Visible = false
		gui.Enabled = shown
	end

	local function SaveToken()
		const Submit = SubmitToken
		if checkingToken or not Submit then
			return
		end
		const candidate = string.gsub(tokenBox.Text, "%s", "")
		if candidate == "" then
			return
		end
		checkingToken = true
		tokenMessage.Text = TOKEN_CHECKING
		tokenMessage.Visible = true
		const problem = Submit(candidate)
		checkingToken = false
		if problem then
			tokenMessage.Text = problem
			return
		end
		CloseTokenBox()
	end

	local function DismissToken()
		if checkingToken then
			return
		end
		const Dismissed = TokenDismissed
		CloseTokenBox()
		if Dismissed then
			Dismissed()
		end
	end

	const connections = {
		saveButton.Activated:Connect(SaveToken),
		closeButton.Activated:Connect(DismissToken),
		tokenBox.FocusLost:Connect(function(enterPressed: boolean)
			if enterPressed then
				SaveToken()
			end
		end),
		pill.Activated:Connect(function()
			details.Visible = not details.Visible
			RefreshDetails()
		end),
		pill.MouseEnter:Connect(ShowHover),
		pill.MouseLeave:Connect(HideHover),
	}

	Show(current)
	gui.Parent = CoreGui

	return {
		Show = Show,
		SetVisible = function(visible: boolean)
			shown = visible
			gui.Enabled = visible or tokenPanel.Visible
			if not visible then
				HideHover()
			end
		end,
		SetHover = function(Read: () -> string)
			ReadHover = Read
		end,
		AskToken = function(prompt: string, Submit: (token: string) -> string?, Dismissed: (() -> ())?)
			SubmitToken = Submit
			TokenDismissed = Dismissed
			tokenPrompt.Text = prompt
			tokenPanel.Visible = true
			gui.Enabled = true
		end,
		CloseTokenBox = CloseTokenBox,
		Destroy = function()
			for _, connection in connections do
				connection:Disconnect()
			end
			gui:Destroy()
		end,
	}
end

return Overlay
