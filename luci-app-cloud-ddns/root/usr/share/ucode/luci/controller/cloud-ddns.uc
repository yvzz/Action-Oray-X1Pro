// luci-app-cloud-ddns controller (ucode)
import { popen, readfile } from 'fs';
import { cursor } from 'uci';

return {
	act_status: function() {
		let f = popen("pgrep -f 'cloud-ddns.sh' | grep -v grep", "r");
		let out = "";
		if (f) { out = f.read("all"); f.close(); }
		http.prepare_content("application/json");
		http.write_json({ running: length(trim(out)) > 0 });
	},

	act_log: function() {
		let log = "";
		try { log = readfile("/var/log/cloud-ddns.log") ?? ""; } catch(e) {}
		http.prepare_content("text/plain; charset=utf-8");
		http.write(log);
	},

	act_restart: function() {
		system("/etc/init.d/cloud-ddns restart >/dev/null 2>&1 &");
		http.prepare_content("application/json");
		http.write_json({ ok: true });
	},

	act_save: function() {
		// Handle POST form submission
		let form = http.formvalues();
		let uci = cursor();

		// DNSPod settings
		uci.set('cloud-ddns', 'dnspod', 'enabled', form.dnspod_enabled == '1' ? '1' : '0');
		uci.set('cloud-ddns', 'dnspod', 'time', form.dnspod_time || '600');
		uci.set('cloud-ddns', 'dnspod', 'mode', form.dnspod_mode || 'token');
		uci.set('cloud-ddns', 'dnspod', 'artoken', form.dnspod_artoken || '');
		uci.set('cloud-ddns', 'dnspod', 'login_email', form.dnspod_login_email || '');
		uci.set('cloud-ddns', 'dnspod', 'login_password', form.dnspod_login_password || '');

		// AliDNS settings
		uci.set('cloud-ddns', 'alidns', 'enabled', form.ali_enabled == '1' ? '1' : '0');
		uci.set('cloud-ddns', 'alidns', 'app_key', form.ali_app_key || '');
		uci.set('cloud-ddns', 'alidns', 'app_secret', form.ali_app_secret || '');

		// IP source
		uci.set('cloud-ddns', 'ip', 'ipv4_source', form.ipv4_source || 'internet');
		uci.set('cloud-ddns', 'ip', 'ipv6_source', form.ipv6_source || 'internet');

		// Domains: delete all existing, re-add from form
		let existing = uci.get_all('cloud-ddns');
		for (let sid in existing) {
			if (existing[sid]?.['.type'] == 'domain')
				uci.delete('cloud-ddns', sid);
		}

		// Parse domain_N_provider, domain_N_record_type, domain_N_main_domain, domain_N_sub_domain
		let i = 0;
		while (form[`domain_${i}_main_domain`] != null) {
			let main = form[`domain_${i}_main_domain`];
			let sub = form[`domain_${i}_sub_domain`];
			if (main && sub) {
				let sid = uci.add('cloud-ddns', 'domain');
				uci.set('cloud-ddns', sid, 'provider', form[`domain_${i}_provider`] || 'dnspod');
				uci.set('cloud-ddns', sid, 'record_type', form[`domain_${i}_record_type`] || 'A');
				uci.set('cloud-ddns', sid, 'main_domain', main);
				uci.set('cloud-ddns', sid, 'sub_domain', sub);
			}
			i++;
		}

		uci.commit('cloud-ddns');

		// Restart service
		system("/etc/init.d/cloud-ddns restart >/dev/null 2>&1 &");

		http.prepare_content("application/json");
		http.write_json({ ok: true });
	}
};