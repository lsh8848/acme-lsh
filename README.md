### VPS本地IP的acme证书申请一键脚本
-------------------------------------
### 一键脚本
```
bash <(curl -Ls https://raw.githubusercontent.com/lsh8848/acme-lsh/main/acme.sh)
```
或者
```
bash <(wget -qO- https://raw.githubusercontent.com/lsh8848/acme-lsh/main/acme.sh)
```
---------------------------------------
#### 功能与特点：
1：支持纯IPV4、纯IPV6、双栈VPS

2：支持80端口模式与DNS API模式，支持单域名与泛域名

3：支持Cloudflare/腾讯DNSPod/阿里Aliyun托管解析平台的DNS API申请

4：查询、撤销并删除当前已申请的域名证书 

5：手动一键或者指定续期域名证书

6：两个证书文件存放在root/lshca目录中

#### 注意：使用80端口模式时，会强制释放80端口，申请证书时先停止nginx，成功后重启nginx

---------------------------------------------



#### 声明：所有代码来源于Github社区与ChatGPT的整合
