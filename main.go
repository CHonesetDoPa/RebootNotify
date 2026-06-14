package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

func sendTelegramMessage(token, chatID string, proxyConfig struct {
	Enabled bool   `yaml:"enabled"`
	Server  string `yaml:"server"`
}, message string) error {
	urlStr := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", token)
	payload := map[string]string{
		"chat_id": chatID,
		"text":    message,
	}
	data, _ := json.Marshal(payload)

	client := &http.Client{}
	if proxyConfig.Enabled && proxyConfig.Server != "" {
		proxy, err := url.Parse(proxyConfig.Server)
		if err != nil {
			return err
		}
		client.Transport = &http.Transport{
			Proxy: http.ProxyURL(proxy),
		}
	}

	resp, err := client.Post(urlStr, "application/json", bytes.NewBuffer(data))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("failed to send message: %s", resp.Status)
	}
	return nil
}

type Config struct {
	Telegram struct {
		Token  string `yaml:"token"`
		ChatID string `yaml:"chat_id"`
	} `yaml:"telegram"`
	Proxy struct {
		Enabled bool   `yaml:"enabled"`
		Server  string `yaml:"server"`
	} `yaml:"proxy"`
	RebootFile     string `yaml:"reboot_file"`
	RebootInterval int    `yaml:"reboot_interval"`
	InitialDelay   int    `yaml:"initial_delay"`
	UpgradeCheck   struct {
		Enabled  bool `yaml:"enabled"`
		Interval int  `yaml:"interval"`
	} `yaml:"upgrade_check"`
}

func checkRebootRequired(path string) bool {
	_, err := os.Stat(path)
	return !os.IsNotExist(err)
}

func getUpgradeablePackages() (string, error) {
	cmd := exec.Command("apt", "list", "--upgradeable")
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if err != nil {
		return "", err
	}
	return out.String(), nil
}

func runRebootCheck(config Config) {
	hostname, _ := os.Hostname()
	fmt.Printf("[%s] Running reboot check...\n", time.Now().Format("2006-01-02 15:04:05"))
	if checkRebootRequired(config.RebootFile) {
		msg := fmt.Sprintf("[%s] System restart required!", hostname)
		err := sendTelegramMessage(config.Telegram.Token, config.Telegram.ChatID, config.Proxy, msg)
		if err != nil {
			fmt.Printf("[%s] Error sending reboot notification: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
		} else {
			fmt.Printf("[%s] Reboot notification sent successfully.\n", time.Now().Format("2006-01-02 15:04:05"))
		}
	} else {
		fmt.Printf("[%s] No reboot required.\n", time.Now().Format("2006-01-02 15:04:05"))
	}
}

func runUpgradeCheck(config Config) {
	hostname, _ := os.Hostname()
	fmt.Printf("[%s] Running upgrade check...\n", time.Now().Format("2006-01-02 15:04:05"))
	pkgs, err := getUpgradeablePackages()
	if err != nil {
		fmt.Printf("[%s] Error checking upgrades: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
		return
	}
	// 过滤掉只有 "Listing..." 头部行的情况，即没有实际可升级包
	lines := strings.Split(strings.TrimSpace(pkgs), "\n")
	var pkgLines []string
	for _, line := range lines {
		if !strings.HasPrefix(line, "Listing...") && strings.TrimSpace(line) != "" {
			pkgLines = append(pkgLines, line)
		}
	}
	if len(pkgLines) == 0 {
		fmt.Printf("[%s] No upgrades available.\n", time.Now().Format("2006-01-02 15:04:05"))
		return
	}
	msg := fmt.Sprintf("[%s] Upgradeable packages available, please run upgrade.", hostname)
	err = sendTelegramMessage(config.Telegram.Token, config.Telegram.ChatID, config.Proxy, msg)
	if err != nil {
		fmt.Printf("[%s] Error sending upgrade notification: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
	} else {
		fmt.Printf("[%s] Upgrade notification sent successfully.\n", time.Now().Format("2006-01-02 15:04:05"))
	}
}

func main() {
	data, err := os.ReadFile("config.yaml")
	if err != nil {
		fmt.Printf("Error reading config: %v\n", err)
		return
	}
	var config Config
	yaml.Unmarshal(data, &config)

	// 获取服务器信息
	hostname, _ := os.Hostname()
	startTime := time.Now().Format("2006-01-02 15:04:05")
	startupMsg := fmt.Sprintf("RebootNotify Started\nHostname: %s\nStartup Time: %s", hostname, startTime)
	fmt.Println(startupMsg)
	sendTelegramMessage(config.Telegram.Token, config.Telegram.ChatID, config.Proxy, startupMsg)

	fmt.Println("Monitoring started...")
	fmt.Printf("Proxy enabled: %v\n", config.Proxy.Enabled)
	if config.Proxy.Enabled {
		fmt.Printf("Proxy server: %s\n", config.Proxy.Server)
	}

	rebootTicker := time.NewTicker(time.Duration(config.RebootInterval) * time.Second)
	defer rebootTicker.Stop()

	var upgradeTicker *time.Ticker
	if config.UpgradeCheck.Enabled {
		upgradeTicker = time.NewTicker(time.Duration(config.UpgradeCheck.Interval) * time.Second)
		defer upgradeTicker.Stop()
	}

	// 启动时立即执行一次初始检查
	if config.InitialDelay > 0 {
		fmt.Printf("Waiting %d seconds for first check...\n", config.InitialDelay)
		time.Sleep(time.Duration(config.InitialDelay) * time.Second)
	}
	runRebootCheck(config)
	if config.UpgradeCheck.Enabled {
		runUpgradeCheck(config)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	for {
		select {
		case <-sig:
			fmt.Println("Shutting down...")
			return
		case <-rebootTicker.C:
			runRebootCheck(config)
		case <-upgradeTicker.C:
			if config.UpgradeCheck.Enabled {
				runUpgradeCheck(config)
			}
		}
	}
}
