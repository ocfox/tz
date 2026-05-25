const types = @import("types");

pub fn callbackButton(text: []const u8, data: []const u8) types.KeyboardButton {
    return .{ .KeyboardButtonCallback = .{ .text = text, .data = data } };
}

pub fn urlButton(text: []const u8, url: []const u8) types.KeyboardButton {
    return .{ .KeyboardButtonUrl = .{ .text = text, .url = url } };
}

pub fn inlineRow(buttons: []types.KeyboardButton) types.KeyboardButtonRow {
    return .{ .buttons = buttons };
}

pub fn inlineKeyboard(rows: []types.KeyboardButtonRow) types.ReplyMarkup {
    return .{ .ReplyInlineMarkup = .{ .rows = rows } };
}
