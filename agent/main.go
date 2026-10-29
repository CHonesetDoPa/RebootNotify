package main

import (
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	AgentID        string           `yaml:"agent_id"`
	Controller     ControllerConfig `yaml:"controller"`
	RebootFile     string           `yaml:"reboot_file"`
	RebootInterval int              `yaml:"reboot_interval"`
	InitialDelay   int              `yaml:"initial_delay"`
	UpgradeCheck   struct {
		Enabled  bool `yaml:"enabled"`
		Interval int  `yaml:"interval"`
	} `yaml:"upgrade_check"`
}

const agentVersion = "1.0.0"

type agentStatus struct {
	sync.RWMutex
	rebootRequired bool
	packages       []string
	runningID      string
	lastError      string
}

var status agentStatus

type ControllerConfig struct {
	Enabled  bool   `yaml:"enabled"`
	URL      string `yaml:"url"`
	Token    string `yaml:"token"`
	Interval int    `yaml:"interval"`
}

func checkRebootRequired(path string) bool {
	_, err := os.Stat(path)
	return !os.IsNotExist(err)
}

func runRebootCheck(config Config) {
	fmt.Printf("[%s] Running reboot check...\n", time.Now().Format("2006-01-02 15:04:05"))
	rebootRequired := checkRebootRequired(config.RebootFile)
	if rebootRequired {
		fmt.Printf("[%s] System restart required.\n", time.Now().Format("2006-01-02 15:04:05"))
	} else {
		fmt.Printf("[%s] No reboot required.\n", time.Now().Format("2006-01-02 15:04:05"))
	}
	status.Lock()
	status.rebootRequired = rebootRequired
	status.Unlock()
}

func runUpgradeCheck(config Config) {
	fmt.Printf("[%s] Running upgrade check...\n", time.Now().Format("2006-01-02 15:04:05"))
	pkgs, err := getUpgradeablePackages()
	if err != nil {
		fmt.Printf("[%s] Error checking upgrades: %v\n", time.Now().Format("2006-01-02 15:04:05"), err)
		status.Lock()
		status.lastError = err.Error()
		status.Unlock()
		return
	}
	if len(pkgs) == 0 {
		fmt.Printf("[%s] No upgrades available.\n", time.Now().Format("2006-01-02 15:04:05"))
	} else {
		fmt.Printf("[%s] %d upgradeable packages found.\n", time.Now().Format("2006-01-02 15:04:05"), len(pkgs))
	}
	status.Lock()
	status.rebootRequired = checkRebootRequired(config.RebootFile)
	status.packages = pkgs
	status.lastError = ""
	status.Unlock()
}

func readStatus() (bool, []string, string, string) {
	status.RLock()
	defer status.RUnlock()
	return status.rebootRequired, append([]string(nil), status.packages...), status.runningID, status.lastError
}

func setRunningCommand(id string) {
	status.Lock()
	status.runningID = id
	status.Unlock()
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
	if err := yaml.Unmarshal(data, &config); err != nil {
		fmt.Printf("Error parsing config: %v\n", err)
		return
	}
	if config.AgentID == "" {
		config.AgentID, _ = os.Hostname()
	}
	if config.RebootInterval <= 0 {
		config.RebootInterval = 3600
	}
	if config.UpgradeCheck.Enabled && config.UpgradeCheck.Interval <= 0 {
		config.UpgradeCheck.Interval = 86400
	}

	hostname, _ := os.Hostname()
	startTime := time.Now().Format("2006-01-02 15:04:05")
	fmt.Printf("RebootNotify started\nHostname: %s\nStartup Time: %s\n", hostname, startTime)
	if config.Controller.Interval <= 0 {
		config.Controller.Interval = 60
	}

	fmt.Println("Monitoring started...")
	fmt.Printf("Controller enabled: %v\n", config.Controller.Enabled)

	rebootTicker := time.NewTicker(time.Duration(config.RebootInterval) * time.Second)
	defer rebootTicker.Stop()

	var upgradeTicker *time.Ticker
	if config.UpgradeCheck.Enabled {
		upgradeTicker = time.NewTicker(time.Duration(config.UpgradeCheck.Interval) * time.Second)
		defer upgradeTicker.Stop()
	}
	var controllerTicker *time.Ticker
	if config.Controller.Enabled {
		controllerTicker = time.NewTicker(time.Duration(config.Controller.Interval) * time.Second)
		defer controllerTicker.Stop()
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
	if config.Controller.Enabled {
		rebootRequired, packages, runningID, lastError := readStatus()
		commands := sendPulse(config, rebootRequired, packages, runningID, lastError)
		startControllerCommands(config, commands)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	var upgradeC <-chan time.Time
	if upgradeTicker != nil {
		upgradeC = upgradeTicker.C
	}
	var controllerC <-chan time.Time
	if controllerTicker != nil {
		controllerC = controllerTicker.C
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
		case <-controllerC:
			rebootRequired, packages, runningID, lastError := readStatus()
			commands := sendPulse(config, rebootRequired, packages, runningID, lastError)
			startControllerCommands(config, commands)
		}
	}
}

func startControllerCommands(config Config, commands []controllerCommand) {
	if len(commands) == 0 {
		return
	}
	command := commands[0]
	status.Lock()
	if status.runningID != "" {
		status.Unlock()
		return
	}
	status.runningID = command.ID
	status.Unlock()
	hostname, _ := os.Hostname()
	go func() {
		executeControllerCommand(config, hostname, command)
		setRunningCommand("")
	}()
}
