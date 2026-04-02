//
//  YouTubeArticleRenderer.swift
//  NetNewsWire
//
//  Renders YouTube feed articles with thumbnails, badges, and linked descriptions.
//

import Foundation
import Articles

/// Generates article body HTML for YouTube feed entries.
///
/// YouTube Atom feeds use media: and yt: namespaced elements that the standard
/// Atom parser stores as metadata in the article body. This renderer extracts
/// that metadata and builds the display HTML at render time, so it works
/// regardless of what format the cached article body is in.
struct YouTubeArticleRenderer {

	struct Metadata {
		let videoID: String
		let isShort: Bool
		let viewCount: String?
		let likeCount: String?
		let description: String?
	}

	// MARK: - API

	/// Returns rendered HTML for a YouTube article, or nil if the article is not from a YouTube feed.
	static func renderedBody(for article: Article) -> String? {
		guard article.feedID.contains("youtube.com/") else {
			return nil
		}

		guard let videoID = videoID(from: article) else {
			return nil
		}

		let meta = metadata(from: article, videoID: videoID)

		return renderHTML(meta: meta)
	}
}

// MARK: - HTML Rendering

private extension YouTubeArticleRenderer {

	static func renderHTML(meta: Metadata) -> String {
		let videoURL = meta.isShort
			? "https://www.youtube.com/shorts/\(meta.videoID)"
			: "https://www.youtube.com/watch?v=\(meta.videoID)"
		let thumbnailURL = "https://i.ytimg.com/vi/\(meta.videoID)/hqdefault.jpg"

		var html = ""

		html += "<a href=\"\(videoURL)\" style=\"display: block;\">"
		html += "<img src=\"\(thumbnailURL)\" style=\"width: 100%; display: block; border-radius: 8px;\" />"
		html += "</a>"

		if meta.isShort {
			html += "<span class=\"nnw-yt-badge nnw-yt-badge-short\">Short</span>"
		} else {
			html += "<span class=\"nnw-yt-badge nnw-yt-badge-video\">Video</span>"
		}

		html += renderMetaBar(meta)

		if let description = meta.description, !description.isEmpty {
			html += renderDescription(description)
		}

		return html
	}

	static func renderMetaBar(_ meta: Metadata) -> String {
		var items = [String]()

		if let views = meta.viewCount {
			items.append("<span>\(formattedCount(views)) views</span>")
		}

		if let likes = meta.likeCount {
			items.append("<span>\(formattedCount(likes)) likes</span>")
		}

		guard !items.isEmpty else {
			return ""
		}

		return "<div class=\"nnw-yt-meta\">" + items.joined() + "</div>"
	}

	static func renderDescription(_ description: String) -> String {
		var escaped = description
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
		escaped = linkURLs(in: escaped)
		escaped = linkHashtags(in: escaped)
		escaped = escaped.replacingOccurrences(of: "\n", with: "<br>")

		return "<p>\(escaped)</p>"
	}

	private static let countFormatter: NumberFormatter = {
		let formatter = NumberFormatter()
		formatter.numberStyle = .decimal
		return formatter
	}()

	static func formattedCount(_ countString: String) -> String {
		guard let count = Int(countString) else {
			return countString
		}
		return countFormatter.string(from: NSNumber(value: count)) ?? countString
	}
}

// MARK: - Video ID Extraction

private extension YouTubeArticleRenderer {

	/// Extracts the YouTube video ID from the article URL or unique ID.
	/// Handles both /watch?v=ID and /shorts/ID URL formats,
	/// and falls back to the yt:video:ID unique ID format from the feed.
	static func videoID(from article: Article) -> String? {
		if let link = article.rawLink {
			// Standard watch URL: https://www.youtube.com/watch?v=VIDEO_ID
			if let components = URLComponents(string: link),
			   let id = components.queryItems?.first(where: { $0.name == "v" })?.value {
				return id
			}
			// Shorts URL: https://www.youtube.com/shorts/VIDEO_ID
			if link.contains("/shorts/") {
				let parts = link.components(separatedBy: "/shorts/")
				if parts.count > 1 {
					return parts[1].components(separatedBy: CharacterSet(charactersIn: "?&#")).first
				}
			}
		}

		// YouTube feed unique IDs are formatted as yt:video:VIDEO_ID
		if article.uniqueID.hasPrefix("yt:video:") {
			return String(article.uniqueID.dropFirst("yt:video:".count))
		}

		return nil
	}
}

// MARK: - Metadata Extraction

private extension YouTubeArticleRenderer {

	/// Extracts YouTube metadata from the article body.
	///
	/// The parser stores metadata in two possible formats depending on when
	/// the article was parsed:
	/// - Current format: a hidden div with data-* attributes (nnw-youtube-meta)
	/// - Legacy format: raw HTML with description in a <p> tag
	static func metadata(from article: Article, videoID: String) -> Metadata {
		// YouTube Shorts use /shorts/ in the permalink URL
		let isShort = article.rawLink?.contains("/shorts/") ?? false

		guard let body = article.body else {
			return Metadata(videoID: videoID, isShort: isShort, viewCount: nil, likeCount: nil, description: nil)
		}

		// Current parser format: metadata stored as data-* attributes
		if body.contains("nnw-youtube-meta") {
			return metadataFromDataAttributes(body, videoID: videoID, isShort: isShort)
		}

		// Legacy or plain text body: extract description only
		let description = descriptionFromBody(body) ?? plainTextDescription(from: body)
		return Metadata(videoID: videoID, isShort: isShort, viewCount: nil, likeCount: nil, description: description)
	}

	/// Extracts metadata from the hidden nnw-youtube-meta div's data-* attributes.
	static func metadataFromDataAttributes(_ body: String, videoID: String, isShort: Bool) -> Metadata {
		let detectedShort = isShort || dataAttribute(body, name: "data-is-short") != nil
		let viewCount = dataAttribute(body, name: "data-views")
		let likeCount = dataAttribute(body, name: "data-likes")
		let description = descriptionFromBody(body)

		return Metadata(videoID: videoID, isShort: detectedShort, viewCount: viewCount, likeCount: likeCount, description: description)
	}

	static func descriptionFromBody(_ body: String) -> String? {
		// Tagged description from current parser format
		if let startRange = body.range(of: "class=\"nnw-youtube-description\">"),
		   let endRange = body.range(of: "</p>", range: startRange.upperBound..<body.endIndex) {
			return unescapeHTML(String(body[startRange.upperBound..<endRange.lowerBound]))
		}

		// Legacy format: plain <p> tag
		if let pRange = body.range(of: "<p>"),
		   let pEndRange = body.range(of: "</p>", range: pRange.upperBound..<body.endIndex) {
			return unescapeHTML(String(body[pRange.upperBound..<pEndRange.lowerBound]))
		}

		return nil
	}

	/// Returns the body as plain text if it doesn't contain any known HTML markers.
	/// This handles cases where the body is just the raw media:description text.
	static func plainTextDescription(from body: String) -> String? {
		if body.contains("nnw-youtube-player") || body.contains("youtube.com/embed/") || body.contains("nnw-youtube-meta") {
			return nil
		}
		return body
	}

	static func unescapeHTML(_ html: String) -> String {
		return html
			.replacingOccurrences(of: "<br>", with: "\n")
			.replacingOccurrences(of: "&amp;", with: "&")
			.replacingOccurrences(of: "&lt;", with: "<")
			.replacingOccurrences(of: "&gt;", with: ">")
	}

	/// Extracts a data-* attribute value from an HTML string by simple string matching.
	static func dataAttribute(_ html: String, name: String) -> String? {
		let needle = "\(name)=\""
		guard let startRange = html.range(of: needle) else {
			return nil
		}
		let valueStart = startRange.upperBound
		guard let endRange = html.range(of: "\"", range: valueStart..<html.endIndex) else {
			return nil
		}
		let value = String(html[valueStart..<endRange.lowerBound])
		return value.isEmpty ? nil : value
	}
}

// MARK: - Auto-Linking

private extension YouTubeArticleRenderer {

	/// Converts bare URLs in text to clickable <a> links.
	/// Processes matches in reverse order to preserve string indices.
	static func linkURLs(in text: String) -> String {
		guard let regex = try? NSRegularExpression(pattern: "(https?://[^\\s<>\"]+)") else {
			return text
		}
		let nsText = text as NSString
		let range = NSRange(location: 0, length: nsText.length)
		var result = text
		for match in regex.matches(in: text, range: range).reversed() {
			guard let fullRange = Range(match.range, in: result) else {
				continue
			}
			let url = String(result[fullRange])
			let replacement = "<a href=\"\(url)\">\(url)</a>"
			result.replaceSubrange(fullRange, with: replacement)
		}
		return result
	}

	/// Converts #hashtags to YouTube hashtag search links.
	/// Processes matches in reverse order to preserve string indices.
	static func linkHashtags(in text: String) -> String {
		guard let regex = try? NSRegularExpression(pattern: "#([a-zA-Z0-9_]+)") else {
			return text
		}
		let nsText = text as NSString
		let range = NSRange(location: 0, length: nsText.length)
		var result = text
		for match in regex.matches(in: text, range: range).reversed() {
			guard let fullRange = Range(match.range, in: result),
				  let tagRange = Range(match.range(at: 1), in: result) else {
				continue
			}
			let tag = String(result[tagRange])
			result.replaceSubrange(fullRange, with: "<a href=\"https://www.youtube.com/hashtag/\(tag)\">#\(tag)</a>")
		}
		return result
	}

}
