// luci-app-cloud-ddns controller (ucode)
import { popen, readfile } from 'fs';
import { cursor } from 'uci';

/*
 * 后台重启服务。
 * stdout/stderr 已重定向到 /dev/null，且命令挂到后台执行，
 * popen() 读到 EOF 即返回，不会被子进程阻塞。
 */
function restart_service() {
	let f = popen('/etc/init.d/cloud-ddns restart >/dev/null 2>&1 &', 'r');
	if (f) f.close();
}

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
		restart_service();
		http.prepare_content("application/json");
		http.write_json({ ok: true });
	},

	act_save: function() {
		// 注意：ucode 的 http 对象没有 formvalues()，formvalue() 不带参数时返回全部参数
		let form = http.formvalue();
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

		// Domains: 先收集待删除的 section，再统一删除（避免遍历中修改）
		let all = uci.get_all('cloud-ddns') ?? {};
		let stale = [];

		for (let sid in all)
			if (all[sid]?.['.type'] == 'domain')
				push(stale, sid);

		for (let j = 0; j < length(stale); j++)
			uci.delete('cloud-ddns', stale[j]);

		// 收集表单里出现的域名序号并升序排列（删除行后索引会不连续）
		let idxs = [];

		for (let k in form) {
			let m = match(k, /^domain_(\d+)_main_domain$/);
			if (m)
				push(idxs, +m[1]);
		}

		/* 简单的数值升序排序，避免依赖 sort() 的比较器行为 */
		for (let a = 0; a < length(idxs); a++) {
			for (let b = a + 1; b < length(idxs); b++) {
				if (idxs[b] < idxs[a]) {
					let t = idxs[a];
					idxs[a] = idxs[b];
					idxs[b] = t;
				}
			}
		}

		for (let j = 0; j < length(idxs); j++) {
			let n = idxs[j];
			let main = form[`domain_${n}_main_domain`];
			let sub = form[`domain_${n}_sub_domain`];

			if (main && sub) {
				let sid = uci.add('cloud-ddns', 'domain');
				uci.set('cloud-ddns', sid, 'provider', form[`domain_${n}_provider`] || 'dnspod');
				uci.set('cloud-ddns', sid, 'record_type', form[`domain_${n}_record_type`] || 'A');
				uci.set('cloud-ddns', sid, 'main_domain', main);
				uci.set('cloud-ddns', sid, 'sub_domain', sub);
			}
		}

		uci.commit('cloud-ddns');

		// 应用配置后重启服务
		restart_service();

		http.prepare_content("application/json");
		http.write_json({ ok: true });
	}
};
