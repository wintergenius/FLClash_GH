package core

import (
	"context"
	"slices"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const (
	postRoamSettleDelay = 150 * time.Millisecond
	postRoamFastTimeout = 1500 * time.Millisecond
)

type postRoamCheckable interface {
	PostRoamCheck(ctx context.Context, fastTimeout time.Duration, force bool) (movedFrom string, movedTo string, changed bool)
}

var (
	postRoamMu     sync.Mutex
	postRoamCancel context.CancelFunc
)

func handleGetTraffic(params TrafficParams) Traffic {
	up, down := statistic.DefaultManager.NowTraffic(params.OnlyProxy)
	return Traffic{Up: up, Down: down}
}

func handleGetTotalTraffic(params TrafficParams) Traffic {
	up, down := statistic.DefaultManager.TotalTraffic(params.OnlyProxy)
	return Traffic{Up: up, Down: down}
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

func handleGetConnections() *statistic.Snapshot {
	return statistic.DefaultManager.Snapshot()
}

func handleGetConnectionCount() int {
	count := 0
	statistic.DefaultManager.Range(func(statistic.Tracker) bool {
		count++
		return true
	})
	return count
}

func handleCloseConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

func isRoamingOutbound(name string) bool {
	if name == "" {
		return false
	}
	proxy, ok := tunnel.AllProxies()[name]
	return ok && proxy.Type() == constant.WireGuard
}

func handleCloseNonRoamingConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		if !isRoamingOutbound(c.Chains().Last()) {
			_ = c.Close()
		}
		return true
	})
}

func handleResetConnections() {
	resolver.ResetConnection()
}

// A network change clears rather than waits out the TTLs: mihomo serves an
// expired entry once more before it refreshes it.
func handleClearDnsCache() {
	configMu.Lock()
	defer configMu.Unlock()
	dns.ClearAll()
}

// handleNetworkChanged is how the desktop host reports a new network, which
// Android's NetworkObserver reports through handleResetNetwork.
func handleNetworkChanged() {
	iface.FlushCache()
	handleClearDnsCache()
	tunnel.ResetWireGuardBinds()
	bumpRouteEpoch()
	schedulePostRoamCheck()
}

func cancelPostRoamCheck() {
	postRoamMu.Lock()
	cancel := postRoamCancel
	postRoamCancel = nil
	postRoamMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func hasGroupActiveConnections(groupName string) bool {
	found := false
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		if slices.Contains([]string(c.Chains()), groupName) {
			found = true
			return false
		}
		return true
	})
	return found
}

func closeMovedGroupConnections(groupName, movedFrom string) {
	if groupName == "" || movedFrom == "" {
		return
	}
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		chains := c.Chains()
		if chains.Last() == movedFrom && slices.Contains([]string(chains), groupName) {
			_ = c.Close()
		}
		return true
	})
}

func runPostRoamCheck(ctx context.Context, settleDelay, fastTimeout time.Duration) {
	if settleDelay > 0 {
		timer := time.NewTimer(settleDelay)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return
		}
	}
	if ctx.Err() != nil {
		return
	}

	type groupTarget struct {
		name  string
		group postRoamCheckable
		force bool
	}
	watched := isRouteWatched()
	var targets []groupTarget
	for name, proxy := range tunnel.AllProxies() {
		if group, ok := adapterAs[postRoamCheckable](proxy); ok {
			targets = append(targets, groupTarget{
				name:  name,
				group: group,
				force: watched || hasGroupActiveConnections(name),
			})
		}
	}
	if len(targets) == 0 {
		return
	}

	var (
		wg       sync.WaitGroup
		anyMoved sync.Mutex
		moved    bool
	)
	for _, target := range targets {
		t := target
		wg.Add(1)
		go func() {
			defer wg.Done()
			movedFrom, _, changed := t.group.PostRoamCheck(ctx, fastTimeout, t.force)
			if changed && ctx.Err() == nil {
				closeMovedGroupConnections(t.name, movedFrom)
				anyMoved.Lock()
				moved = true
				anyMoved.Unlock()
			}
		}()
	}
	wg.Wait()

	if moved && ctx.Err() == nil {
		bumpRouteEpoch()
	}
}

func schedulePostRoamCheck() {
	if !isRunning.Load() {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	postRoamMu.Lock()
	prev := postRoamCancel
	postRoamCancel = cancel
	postRoamMu.Unlock()
	if prev != nil {
		prev()
	}
	go runPostRoamCheck(ctx, postRoamSettleDelay, postRoamFastTimeout)
}

// A direct or TCP-proxied connection that went out over a network the device
// has left hangs until TCP gives up on it, whereas WireGuard/AmneziaWG inner
// streams survive roaming once ResetWireGuardBinds rebinds their outer socket.
func handleResetNetwork() {
	handleCloseNonRoamingConnections()
	handleNetworkChanged()
}

// A connection that is already gone is closed as far as the host is concerned.
func handleCloseConnection(params IDParams) error {
	if c := statistic.DefaultManager.Get(params.ID); c != nil {
		_ = c.Close()
	}
	return nil
}
