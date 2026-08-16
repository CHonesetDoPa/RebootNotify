package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

const telegramMessageLimit = 3800
const telegramQuotedTextLimit = 3000
const telegramRequestTimeout = 60 * time.Second
const telegramLongPollTimeout = 25

var upgradeablePackageLinePattern = regexp.MustCompile(`^[^\s/]+/[^\s]+\s+`)

type ProxyConfig struct {
	Enabled bool   `yaml:"enabled"`
	Server  string `yaml:"server"`
}

type TelegramConfig struct {
	Token  string `yaml:"token"`
	ChatID string `yaml:"chat_id"`
}

type telegramMessageRequest struct {
	ChatID      string `json:"chat_id"`
	Text        string `json:"text"`
	ParseMode   string `json:"parse_mode,omitempty"`
	ReplyMarkup any    `json:"reply_markup,omitempty"`
}

type telegramInlineKeyboardButton struct {
	Text         string `json:"text"`
	CallbackData string `json:"callback_data"`
}

type telegramInlineKeyboardMarkup struct {
	InlineKeyboard [][]telegramInlineKeyboardButton `json:"inline_keyboard"`
}

type telegramUpdatesResponse struct {
	Ok     bool             `json:"ok"`
	Result []telegramUpdate `json:"result"`
}

type telegramUpdate struct {
	UpdateID      int                    `json:"update_id"`
	CallbackQuery *telegramCallbackQuery `json:"callback_query,omitempty"`
}

type telegramCallbackQuery struct {
	ID      string          `json:"id"`
	Data    string          `json:"data"`
	Message telegramMessage `json:"message"`
	From    telegramUser    `json:"from"`
}

type telegramMessage struct {
	MessageID int64        `json:"message_id"`
	Chat      telegramChat `json:"chat"`
}

type telegramChat struct {
	ID int64 `json:"id"`
}

type telegramUser struct {
	ID int64 `json:"id"`
}

type TelegramBot struct {
	token       string
	chatID      string
	httpClient  *http.Client
	updateQueue chan telegramUpdateRequest
}

type telegramUpdateRequest struct {
	callbackQueryID string
}

func newHTTPClient(proxyConfig ProxyConfig) (*http.Client, error) {
	client := &http.Client{Timeout: telegramRequestTimeout}
	if proxyConfig.Enabled && proxyConfig.Server != "" {
		proxy, err := url.Parse(proxyConfig.Server)
		if err != nil {
			return nil, err
		}
		client.Transport = &http.Transport{Proxy: http.ProxyURL(proxy)}
	}
	return client, nil
}

func newTelegramBot(config Config) (*TelegramBot, error) {
	client, err := newHTTPClient(config.Proxy)
	if err != nil {
		return nil, err
	}
	return &TelegramBot{
		token:       config.Telegram.Token,
		chatID:      config.Telegram.ChatID,
		httpClient:  client,
		updateQueue: make(chan telegramUpdateRequest, 8),
	}, nil
}

func sendTelegramMessage(token, chatID string, proxyConfig ProxyConfig, message string, replyMarkup ...any) error {
	client, err := newHTTPClient(proxyConfig)
	if err != nil {
		return err
	}
	return sendTelegramMessageWithClient(client, token, chatID, message, replyMarkup...)
}

func sendTelegramMessageWithClient(client *http.Client, token, chatID, message string, replyMarkup ...any) error {
	urlStr := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", token)
	payload := telegramMessageRequest{
		ChatID: chatID,
		Text:   message,
	}
	if len(replyMarkup) > 0 {
		payload.ReplyMarkup = replyMarkup[0]
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	resp, err := client.Post(urlStr, "application/json", bytes.NewBuffer(data))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		trimmedBody := strings.TrimSpace(string(body))
		if trimmedBody != "" {
			return fmt.Errorf("failed to send message: %s: %s", resp.Status, trimmedBody)
		}
		return fmt.Errorf("failed to send message: %s", resp.Status)
	}
	return nil
}

func sendTelegramHTMLMessageWithClient(client *http.Client, token, chatID, message string, replyMarkup ...any) error {
	urlStr := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", token)
	payload := telegramMessageRequest{
		ChatID:    chatID,
		Text:      message,
		ParseMode: "HTML",
	}
	if len(replyMarkup) > 0 {
		payload.ReplyMarkup = replyMarkup[0]
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	resp, err := client.Post(urlStr, "application/json", bytes.NewBuffer(data))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		trimmedBody := strings.TrimSpace(string(body))
		if trimmedBody != "" {
			return fmt.Errorf("failed to send message: %s: %s", resp.Status, trimmedBody)
		}
		return fmt.Errorf("failed to send message: %s", resp.Status)
	}
	return nil
}

func (b *TelegramBot) sendMessage(message string, replyMarkup ...any) error {
	return sendTelegramMessageWithClient(b.httpClient, b.token, b.chatID, message, replyMarkup...)
}

func (b *TelegramBot) sendHTMLMessage(message string, replyMarkup ...any) error {
	return sendTelegramHTMLMessageWithClient(b.httpClient, b.token, b.chatID, message, replyMarkup...)
}

func getUpgradeablePackages() ([]string, error) {
	cmd := exec.Command("apt", "list", "--upgradeable")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("apt list --upgradeable failed: %w: %s", err, strings.TrimSpace(string(output)))
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	packages := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || !upgradeablePackageLinePattern.MatchString(trimmed) {
			continue
		}
		packages = append(packages, trimmed)
	}
	return packages, nil
}

func formatUpgradeablePackageList(packages []string) string {
	if len(packages) == 0 {
		return "No upgrades available."
	}
	return strings.Join(packages, "\n")
}

func splitTelegramMessage(header, body string, limit int) []string {
	if limit <= 0 {
		limit = telegramMessageLimit
	}
	if len(header) >= limit {
		return []string{header}
	}

	lines := strings.Split(body, "\n")
	chunks := make([]string, 0, 2)
	current := header

	for _, line := range lines {
		candidate := current
		if candidate != header {
			candidate += "\n"
		}
		candidate += line

		if len(candidate) > limit {
			if current == header {
				chunks = append(chunks, candidate)
				current = header
				continue
			}
			chunks = append(chunks, current)
			current = line
			continue
		}

		current = candidate
	}

	if current != "" && current != header {
		chunks = append(chunks, current)
	}

	if len(chunks) == 0 {
		chunks = append(chunks, header)
	}

	return chunks
}

func splitTextIntoChunks(text string, limit int) []string {
	if limit <= 0 {
		limit = telegramQuotedTextLimit
	}
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return []string{""}
	}

	lines := strings.Split(trimmed, "\n")
	chunks := make([]string, 0, len(lines))
	var current strings.Builder

	flush := func() {
		if current.Len() == 0 {
			return
		}
		chunks = append(chunks, current.String())
		current.Reset()
	}

	for _, line := range lines {
		if current.Len() == 0 {
			if len(line) <= limit {
				current.WriteString(line)
				continue
			}
			for start := 0; start < len(line); start += limit {
				end := start + limit
				if end > len(line) {
					end = len(line)
				}
				chunks = append(chunks, line[start:end])
			}
			continue
		}

		candidateLen := current.Len() + 1 + len(line)
		if candidateLen <= limit {
			current.WriteByte('\n')
			current.WriteString(line)
			continue
		}

		flush()
		if len(line) <= limit {
			current.WriteString(line)
			continue
		}
		for start := 0; start < len(line); start += limit {
			end := start + limit
			if end > len(line) {
				end = len(line)
			}
			chunks = append(chunks, line[start:end])
		}
	}

	flush()
	return chunks
}

func buildExpandableQuoteMessage(title, body string) string {
	escapedTitle := html.EscapeString(title)
	escapedBody := html.EscapeString(strings.TrimSpace(body))
	if escapedBody == "" {
		return fmt.Sprintf("<b>%s</b>", escapedTitle)
	}
	return fmt.Sprintf("<b>%s</b>\n<blockquote expandable>%s</blockquote>", escapedTitle, escapedBody)
}

func (b *TelegramBot) sendQuotedMessage(title, body string, replyMarkup ...any) error {
	chunks := splitTextIntoChunks(body, telegramQuotedTextLimit)
	if len(chunks) == 0 {
		chunks = []string{""}
	}

	for i, chunk := range chunks {
		messageTitle := title
		if len(chunks) > 1 {
			messageTitle = fmt.Sprintf("%s (Part %d/%d)", title, i+1, len(chunks))
		}
		message := buildExpandableQuoteMessage(messageTitle, chunk)
		if i == len(chunks)-1 {
			if err := b.sendHTMLMessage(message, replyMarkup...); err != nil {
				return err
			}
			continue
		}
		if err := b.sendHTMLMessage(message); err != nil {
			return err
		}
	}

	return nil
}

func (b *TelegramBot) sendUpgradeablePackages(packages []string) error {
	return b.sendQuotedMessage("Upgradeable packages", formatUpgradeablePackageList(packages), runUpdateKeyboard())
}

func upgradePackageKeyboard() telegramInlineKeyboardMarkup {
	return telegramInlineKeyboardMarkup{
		InlineKeyboard: [][]telegramInlineKeyboardButton{{
			{Text: "Show Upgradeable Packages", CallbackData: "show_updates"},
		}},
	}
}

func runUpdateKeyboard() telegramInlineKeyboardMarkup {
	return telegramInlineKeyboardMarkup{
		InlineKeyboard: [][]telegramInlineKeyboardButton{{
			{Text: "Run Upgrade", CallbackData: "run_upgrade"},
		}},
	}
}

func (b *TelegramBot) startPolling(stop <-chan struct{}) {
	if b == nil || b.token == "" || b.chatID == "" {
		return
	}

	go b.processUpdateQueue(stop)

	go func() {
		offset := 0
		for {
			select {
			case <-stop:
				return
			default:
			}

			updates, err := b.getUpdates(offset)
			if err != nil {
				fmt.Printf("[%s] Telegram polling error: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
				time.Sleep(5 * time.Second)
				continue
			}

			for _, update := range updates {
				if update.UpdateID >= offset {
					offset = update.UpdateID + 1
				}
				if update.CallbackQuery == nil {
					continue
				}
				b.handleCallbackQuery(*update.CallbackQuery)
			}
		}
	}()
}

func (b *TelegramBot) getUpdates(offset int) ([]telegramUpdate, error) {
	urlStr := fmt.Sprintf("https://api.telegram.org/bot%s/getUpdates?timeout=%d&offset=%d", b.token, telegramLongPollTimeout, offset)
	req, err := http.NewRequest(http.MethodGet, urlStr, nil)
	if err != nil {
		return nil, err
	}

	resp, err := b.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("getUpdates failed: %s", resp.Status)
	}

	var payload telegramUpdatesResponse
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	if !payload.Ok {
		return nil, fmt.Errorf("telegram getUpdates returned not ok")
	}
	return payload.Result, nil
}

func (b *TelegramBot) handleCallbackQuery(callback telegramCallbackQuery) {
	if fmt.Sprint(callback.Message.Chat.ID) != b.chatID {
		return
	}

	switch callback.Data {
	case "show_updates":
		if err := b.answerCallbackQuery(callback.ID, "Checking for upgradeable packages..."); err != nil {
			fmt.Printf("[%s] Error answering callback: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
		}
		packages, err := getUpgradeablePackages()
		if err != nil {
			_ = b.sendMessage(fmt.Sprintf("Failed to fetch the upgrade list: %v", err))
			return
		}
		if err := b.sendUpgradeablePackages(packages); err != nil {
			fmt.Printf("[%s] Error sending package list: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
		}
	case "run_upgrade":
		if !b.enqueueUpdate(telegramUpdateRequest{callbackQueryID: callback.ID}) {
			_ = b.answerCallbackQuery(callback.ID, "The update queue is full. Please try again later.")
			return
		}
		if err := b.answerCallbackQuery(callback.ID, "Queued for update. It will run shortly..."); err != nil {
			fmt.Printf("[%s] Error answering callback: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
		}
	}
}

func (b *TelegramBot) enqueueUpdate(request telegramUpdateRequest) bool {
	select {
	case b.updateQueue <- request:
		return true
	default:
		return false
	}
}

func (b *TelegramBot) processUpdateQueue(stop <-chan struct{}) {
	for {
		select {
		case <-stop:
			return
		case request := <-b.updateQueue:
			if err := b.answerCallbackQuery(request.callbackQueryID, "Starting the update..."); err != nil {
				fmt.Printf("[%s] Error answering callback: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
			}
			output, err := runPackageUpgrade()
			if err != nil {
				_ = b.sendQuotedMessage("Package update failed", fmt.Sprintf("%v\n\n%s", err, output))
				continue
			}
			if output == "" {
				output = "Update complete."
			}
			_ = b.sendQuotedMessage("Package update complete", output)
		}
	}
}

func (b *TelegramBot) answerCallbackQuery(callbackQueryID, text string) error {
	urlStr := fmt.Sprintf("https://api.telegram.org/bot%s/answerCallbackQuery", b.token)
	payload := map[string]string{
		"callback_query_id": callbackQueryID,
		"text":              text,
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequest(http.MethodPost, urlStr, bytes.NewBuffer(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := b.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("answerCallbackQuery failed: %s", resp.Status)
	}
	return nil
}

func runPackageUpgrade() (string, error) {
	cmd := exec.Command("bash", "-lc", "DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Lock::Timeout=600 update && DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Lock::Timeout=600 upgrade -y")
	output, err := cmd.CombinedOutput()
	return string(output), err
}
