package core

import (
	"context"
	"encoding/base64"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestProxyOnlyTrafficLeavesOutADirectProxyOfAnyName(t *testing.T) {
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "直连"})
	reject := outbound.NewRejectWithOption(outbound.RejectOption{Name: "HK"})
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"直连": adapter.NewProxy(direct),
		"HK": adapter.NewProxy(reject),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	for _, test := range []struct {
		outbound constant.ProxyAdapter
		proxied  int64
	}{
		{direct, 0},
		{reject, 5},
	} {
		statistic.DefaultManager.ResetStatistic()
		local, remote := net.Pipe()
		go func() { _, _ = io.Copy(io.Discard, remote) }()
		tracker := statistic.NewTCPTracker(
			outbound.NewConn(local, test.outbound),
			statistic.DefaultManager,
			&constant.Metadata{},
			nil,
			0,
			0,
			true,
		)

		if _, err := tracker.Write([]byte("hello")); err != nil {
			t.Fatalf("write through %s: %v", test.outbound.Name(), err)
		}
		_ = tracker.Close()
		_ = remote.Close()

		all, _ := statistic.DefaultManager.TotalTraffic(false)
		proxied, _ := statistic.DefaultManager.TotalTraffic(true)
		if all != 5 || proxied != test.proxied {
			t.Errorf("%s: total %d, proxied %d; want 5 and %d", test.outbound.Name(), all, proxied, test.proxied)
		}
	}
	statistic.DefaultManager.ResetStatistic()
}

type fakeWireGuardRebindAdapter struct {
	outbound.ProxyAdapter
	rebinds atomic.Int32
}

func (f *fakeWireGuardRebindAdapter) Name() string               { return "WG-NL" }
func (f *fakeWireGuardRebindAdapter) Type() constant.AdapterType { return constant.WireGuard }
func (f *fakeWireGuardRebindAdapter) Rebind()                    { f.rebinds.Add(1) }

func TestResetNetworkClosesDirectButPreservesWireGuardStreams(t *testing.T) {
	direct := outbound.NewDirect()
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	parsedWG, err := adapter.ParseProxy(map[string]any{
		"name":        "WG-DE",
		"type":        "wireguard",
		"server":      "198.51.100.2",
		"port":        51820,
		"ip":          "10.10.0.2/32",
		"private-key": key,
		"public-key":  key,
		"udp":         true,
	})
	if err != nil {
		t.Fatalf("ParseProxy wireguard: %v", err)
	}
	t.Cleanup(func() { _ = parsedWG.Close() })

	rebindWG := &fakeWireGuardRebindAdapter{ProxyAdapter: direct}
	wrappedWG := outbound.NewAutoCloseProxyAdapter(rebindWG)
	t.Cleanup(func() { _ = wrappedWG.Close() })
	wgProxy := adapter.NewProxy(wrappedWG)

	tunnel.UpdateProxies(map[string]constant.Proxy{
		"DIRECT": adapter.NewProxy(direct),
		"WG-NL":  wgProxy,
		"WG-DE":  parsedWG,
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	directLocal, directRemote := net.Pipe()
	t.Cleanup(func() { _ = directRemote.Close() })
	directTracker := statistic.NewTCPTracker(
		outbound.NewConn(directLocal, direct),
		statistic.DefaultManager,
		&constant.Metadata{},
		nil,
		0,
		0,
		false,
	)

	wgLocal, wgRemote := net.Pipe()
	t.Cleanup(func() {
		_ = wgLocal.Close()
		_ = wgRemote.Close()
	})
	wgConn := outbound.NewConn(wgLocal, wgProxy)
	wgConn.AppendToChains(
		adapter.NewProxy(outbound.NewRejectWithOption(outbound.RejectOption{Name: "⚡ Авто"})),
	)
	wgTracker := statistic.NewTCPTracker(
		wgConn,
		statistic.DefaultManager,
		&constant.Metadata{},
		nil,
		0,
		0,
		false,
	)

	handleResetNetwork()

	if statistic.DefaultManager.Get(directTracker.ID()) != nil {
		t.Fatalf("expected DIRECT tracker to be closed on network reset")
	}
	if statistic.DefaultManager.Get(wgTracker.ID()) == nil {
		t.Fatalf("expected WireGuard tracker to stay open across network reset")
	}
	if got := rebindWG.rebinds.Load(); got != 1 {
		t.Fatalf("expected WireGuard adapter Rebind() once, got %d", got)
	}

	_ = wgTracker.Close()
}

type fakePostRoamGroup struct {
	constant.ProxyAdapter
	movedFrom string
	movedTo   string
	changed   bool
}

func (g *fakePostRoamGroup) PostRoamCheck(_ context.Context, _ time.Duration, _ bool) (string, string, bool) {
	return g.movedFrom, g.movedTo, g.changed
}

func TestRunPostRoamCheckClosesStuckConnectionsOnDeadMemberOnly(t *testing.T) {
	direct := outbound.NewDirect()
	deadWG := adapter.NewProxy(&fakeWireGuardRebindAdapter{ProxyAdapter: direct})
	liveWG := adapter.NewProxy(outbound.NewRejectWithOption(outbound.RejectOption{Name: "WG-LV"}))
	autoGroup := adapter.NewProxy(&fakePostRoamGroup{
		ProxyAdapter: outbound.NewRejectWithOption(outbound.RejectOption{Name: "⚡ Авто"}),
		movedFrom:    "WG-NL",
		movedTo:      "WG-LV",
		changed:      true,
	})

	tunnel.UpdateProxies(map[string]constant.Proxy{
		"WG-NL":  deadWG,
		"WG-LV":  liveWG,
		"⚡ Авто": autoGroup,
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	deadLocal, deadRemote := net.Pipe()
	t.Cleanup(func() { _ = deadRemote.Close() })
	deadConn := outbound.NewConn(deadLocal, deadWG)
	deadConn.AppendToChains(autoGroup)
	deadTracker := statistic.NewTCPTracker(deadConn, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, false)

	liveLocal, liveRemote := net.Pipe()
	t.Cleanup(func() {
		_ = liveLocal.Close()
		_ = liveRemote.Close()
	})
	liveConn := outbound.NewConn(liveLocal, liveWG)
	liveConn.AppendToChains(autoGroup)
	liveTracker := statistic.NewTCPTracker(liveConn, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, false)
	t.Cleanup(func() { _ = liveTracker.Close() })

	runPostRoamCheck(context.Background(), 0, 50*time.Millisecond)

	if statistic.DefaultManager.Get(deadTracker.ID()) != nil {
		t.Fatal("expected tracker pinned to dead primary WG-NL to be closed after group failover")
	}
	if statistic.DefaultManager.Get(liveTracker.ID()) == nil {
		t.Fatal("expected tracker on live backup WG-LV to remain open")
	}
}

func TestCancelPostRoamCheckAbortsPendingSettleTimer(t *testing.T) {
	direct := outbound.NewDirect()
	deadWG := adapter.NewProxy(&fakeWireGuardRebindAdapter{ProxyAdapter: direct})
	liveWG := adapter.NewProxy(outbound.NewRejectWithOption(outbound.RejectOption{Name: "WG-LV"}))
	autoGroup := adapter.NewProxy(&fakePostRoamGroup{
		ProxyAdapter: outbound.NewRejectWithOption(outbound.RejectOption{Name: "⚡ Авто"}),
		movedFrom:    "WG-NL",
		movedTo:      "WG-LV",
		changed:      true,
	})

	tunnel.UpdateProxies(map[string]constant.Proxy{
		"WG-NL":  deadWG,
		"WG-LV":  liveWG,
		"⚡ Авто": autoGroup,
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	local, remote := net.Pipe()
	t.Cleanup(func() {
		_ = local.Close()
		_ = remote.Close()
	})
	conn := outbound.NewConn(local, deadWG)
	conn.AppendToChains(autoGroup)
	tracker := statistic.NewTCPTracker(conn, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, false)
	t.Cleanup(func() { _ = tracker.Close() })

	schedulePostRoamCheck()
	cancelPostRoamCheck()
	time.Sleep(postRoamSettleDelay + 40*time.Millisecond)

	if statistic.DefaultManager.Get(tracker.ID()) == nil {
		t.Fatal("canceled post-roam check must not close connections after profile reload/stop")
	}
}
