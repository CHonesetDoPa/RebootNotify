package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Telegram       TelegramConfig `yaml:"telegram"`
	Proxy          ProxyConfig    `yaml:"proxy"`
	RebootFile     string         `yaml:"reboot_file"`
	RebootInterval int            `yaml:"reboot_interval"`
	InitialDelay   int            `yaml:"initial_delay"`
	UpgradeCheck   struct {
		Enabled  bool `yaml:"enabled"`
		Interval int  `yaml:"interval"`
	} `yaml:"upgrade_check"`
}

func checkRebootRequired(path string) bool {
	_, err := os.Stat(path)
	return !os.IsNotExist(err)
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
	if len(pkgs) == 0 {
		fmt.Printf("[%s] No upgrades available.\n", time.Now().Format("2006-01-02 15:04:05"))
		return
	}
	msg := fmt.Sprintf("[%s] Upgradeable packages were found. Tap the button to view the list.", hostname)
	err = sendTelegramMessage(config.Telegram.Token, config.Telegram.ChatID, config.Proxy, msg, upgradePackageKeyboard())
	if err != nil {
		fmt.Printf("[%s] Error sending upgrade notification: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
	} else {
		fmt.Printf("[%s] Upgrade notification sent successfully.\n", time.Now().Format("2006-01-02 15:04:05"))
	}
}

func main() {
	if os.Geteuid() != 0 {
		fmt.Println("Error: RebootNotify must run as root because it calls apt/apt-get.")
		os.Exit(1)
	}

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

	bot, err := newTelegramBot(config)
	if err != nil {
		fmt.Printf("Error initializing Telegram bot: %v\n", err)
	} else {
		stopTelegram := make(chan struct{})
		defer close(stopTelegram)
		bot.startPolling(stopTelegram)
	}

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

	var upgradeC <-chan time.Time
	if upgradeTicker != nil {
		upgradeC = upgradeTicker.C
	}

	for {
		select {
		case <-sig:
			fmt.Println("Shutting down...")
			return
		case <-rebootTicker.C:
			runRebootCheck(config)
		case <-upgradeC:
			if config.UpgradeCheck.Enabled {
				runUpgradeCheck(config)
			}
		}
	}
}
