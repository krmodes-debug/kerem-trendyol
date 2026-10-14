import streamlit as st
import requests
import xml.etree.ElementTree as ET
import pandas as pd
import base64
import json
import time
from datetime import datetime

# Sayfa Yapılandırması (Mobil ve Masaüstü Uyumlu)
st.set_page_config(
    page_title="Kerem Reis",
    layout="wide",
    page_icon="🚀",
    initial_sidebar_state="collapsed"
)

# Mobil Uyumlu Özel CSS (Büyük dokunmatik butonlar ve kompakt ekran)
st.markdown("""
<style>
    .block-container {
        padding-top: 1.2rem;
        padding-bottom: 2rem;
        padding-left: 0.8rem;
        padding-right: 0.8rem;
    }
    .stButton > button {
        width: 100%;
        min-height: 3.2rem;
        font-weight: 700;
        border-radius: 12px;
    }
    div[data-testid="stMetricValue"] {
        font-size: 1.4rem;
    }
</style>
""", unsafe_allow_html=True)

st.title("🚀 Kerem Reis")
st.caption("📱 Mobil Uyumlu Trendyol XML Entegrasyon & Otomasyon Paneli")

# --- CLOUD SECRETS VEYA VARSAYILAN DEĞERLER ---
def get_secret(key, default=""):
    try:
        return st.secrets.get(key, default)
    except Exception:
        return default

# --- SOL MENÜ & MOBİL AYAR KUTUSU ---
with st.sidebar:
    st.header("⚙️ Trendyol API Bilgileri")
    supplier_id = st.text_input("Satıcı ID (Supplier ID)", value=get_secret("SUPPLIER_ID", ""), placeholder="Örn: 123456")
    api_key = st.text_input("API Key", value=get_secret("API_KEY", ""), placeholder="Trendyol API Key")
    api_secret = st.text_input("API Secret", value=get_secret("API_SECRET", ""), type="password", placeholder="Trendyol API Secret")
    
    st.divider()
    st.header("💰 Fiyat & Kar Marjı")
    profit_rate = st.number_input("Kar Oranı (%)", min_value=0.0, value=35.0, step=5.0)
    extra_cost = st.number_input("Sabit Ek Maliyet / Kargo (TL)", min_value=0.0, value=60.0, step=10.0)
    vat_rate = st.selectbox("KDV Oranı (%)", [10, 20, 1], index=0)
    min_stock_limit = st.number_input("Kritik Stok Alt Limiti", min_value=0, value=1, help="XML'de bu sayının altındaki stokları Trendyol'a 0 olarak gönderir.")
    
    st.divider()
    st.header("🏷️ Varsayılan Eşleştirmeler")
    default_Category_id = st.number_input("Trendyol Kategori ID", value=1172, help="4. Sekmeden arayıp bulabilirsiniz.")
    default_brand_id = st.number_input("Trendyol Marka ID", value=1804, help="4. Sekmeden arayıp bulabilirsiniz.")

# Mobilde sol menüyü açmadan hızlıca ayar değiştirmek için pratik kutu
with st.expander("📲 Mobil Hızlı Ayarlar (API & Kar Oranı)", expanded=not bool(supplier_id)):
    m_col1, m_col2 = st.columns(2)
    with m_col1:
        if not supplier_id:
            supplier_id = st.text_input("Satıcı ID", key="m_sup")
        if not api_key:
            api_key = st.text_input("API Key", key="m_key")
        if not api_secret:
            api_secret = st.text_input("API Secret", type="password", key="m_sec")
    with m_col2:
        st.write(f"**Aktif Kar Oranı:** %{profit_rate} + {extra_cost} TL")
        st.write(f"**Kategori ID:** `{default_Category_id}` | **Marka ID:** `{default_brand_id}`")
        st.caption("Detaylı ayarlar için sol üstteki **>** (Menü) ikonuna dokunun.")

# --- XML LINK GİRİŞİ ---
xml_url = st.text_input(
    "🔗 Tedarikçi XML Adresi", 
    value="https://xml1.xmlbankasi.com/p1/xbirhwryqfpe/image/data/xml/standart.xml"
)

# --- YARDIMCI FONKSİYONLAR ---
def get_trendyol_headers(sup_id, key, secret):
    auth_str = f"{key}:{secret}"
    b64_auth = base64.b64encode(auth_str.encode()).decode()
    return {
        "Authorization": f"Basic {b64_auth}",
        "User-Agent": f"{sup_id} - SelfIntegration",
        "Content-Type": "application/json"
    }

def normalize_tr(text):
    if not text:
        return ""
    text = str(text).strip()
    replacements = {
        "İ": "i", "I": "ı", "Ğ": "ğ", "Ü": "ü", "Ş": "ş", "Ö": "ö", "Ç": "ç"
    }
    for k, v in replacements.items():
        text = text.replace(k, v)
    return text.lower()

@st.cache_data(ttl=3600)
def fetch_trendyol_categories():
    url = "https://api.trendyol.com/sapigw/product-categories"
    headers = {"User-Agent": "Mozilla/5.0"}
    res = requests.get(url, headers=headers, timeout=30)
    res.raise_for_status()
    data = res.json().get("categories", [])
    
    flat_list = []
    def traverse(cats, parent_path=""):
        for c in cats:
            current_path = f"{parent_path} > {c['name']}" if parent_path else c['name']
            sub_cats = c.get("subCategories", [])
            if not sub_cats:
                flat_list.append({
                    "Kategori ID": c["id"],
                    "Kategori Adı": c["name"],
                    "Tam Kategori Yolu": current_path,
                    "Üst Kategori ID": c.get("parentId", "")
                })
            else:
                traverse(sub_cats, current_path)
                
    traverse(data)
    return pd.DataFrame(flat_list)

@st.cache_data(ttl=3600)
def get_category_attributes_dict(cat_id):
    url = f"https://api.trendyol.com/sapigw/product-categories/{int(cat_id)}/attributes"
    res = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=20)
    if res.status_code != 200:
        return None
    
    cat_attrs = res.json().get("categoryAttributes", [])
    parsed = {
        "size_attr": None,
        "color_attr": None,
        "required_attrs": [],
        "all_attrs": []
    }
    
    for ca in cat_attrs:
        attr_id = ca.get("attribute", {}).get("id")
        attr_name = ca.get("attribute", {}).get("name", "")
        required = ca.get("required", False)
        varianter = ca.get("varianter", False)
        allow_custom = ca.get("allowCustom", False)
        values = ca.get("attributeValues", [])
        
        val_map = {normalize_tr(v.get("name", "")): v.get("id") for v in values if v.get("name")}
        
        item_info = {
            "id": attr_id,
            "name": attr_name,
            "required": required,
            "varianter": varianter,
            "allowCustom": allow_custom,
            "values": values,
            "val_map": val_map
        }
        parsed["all_attrs"].append(item_info)
        
        norm_name = normalize_tr(attr_name)
        if norm_name in ["beden", "numara", "ekartman"] or (varianter and "renk" not in norm_name):
            parsed["size_attr"] = item_info
        elif "renk" in norm_name:
            parsed["color_attr"] = item_info
        elif required:
            parsed["required_attrs"].append(item_info)
            
    return parsed

def resolve_attribute_payload(attr_info, raw_value):
    if not attr_info or not raw_value or str(raw_value).strip() in ["", "Standart"]:
        return None
        
    attr_id = attr_info["id"]
    val_map = attr_info["val_map"]
    clean_val = normalize_tr(raw_value)
    
    if clean_val in val_map:
        return {"attributeId": attr_id, "attributeValueId": val_map[clean_val]}
        
    clean_num = clean_val.replace(".0", "").replace("numara", "").replace("no", "").strip()
    if clean_num in val_map:
        return {"attributeId": attr_id, "attributeValueId": val_map[clean_num]}
        
    for k, v_id in val_map.items():
        if clean_num == k or (len(clean_num) > 2 and clean_num in k):
            return {"attributeId": attr_id, "attributeValueId": v_id}
            
    if attr_info.get("allowCustom"):
        return {"attributeId": attr_id, "customAttributeValue": str(raw_value).strip()}
        
    return None

def fetch_and_parse_xml(url):
    headers = {"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"}
    response = requests.get(url, headers=headers, timeout=30)
    response.raise_for_status()
    
    root = ET.fromstring(response.content)
    product_nodes = (
        root.findall(".//Product") or 
        root.findall(".//product") or 
        root.findall(".//urun") or 
        root.findall(".//item") or 
        list(root)
    )
    
    parsed_items = []
    raw_sample = ET.tostring(product_nodes[0], encoding="unicode") if product_nodes else ""

    for node in product_nodes:
        def get_text(tags, default=""):
            for t in tags:
                el = node.find(t)
                if el is not None and el.text:
                    return el.text.strip()
            return default

        urun_kodu = get_text(["Product_code", "UrunKodu", "StokKodu", "model_kodu", "sku", "id"])
        urun_adi = get_text(["Name", "UrunAdi", "Baslik", "name", "title"])
        marka = get_text(["Brand", "Marka", "brand"], "Chekich")
        kategori = get_text(["Category", "Kategori", "main_category", "category"])
        aciklama = get_text(["Description", "Aciklama", "Detay", "description"], urun_adi)
        fiyat_str = get_text(["Price", "SatisFiyati", "Fiyat", "AlisFiyati", "price"], "0")
        renk = get_text(["Color", "Renk", "color"], "Siyah")
        
        try:
            alis_fiyati = float(fiyat_str.replace(",", "."))
        except:
            alis_fiyati = 0.0

        images = []
        for img_tag in ["Image1", "Image2", "Image3", "Image4", "Image5", "Resim1", "Resim2", "Resim3", "image", "picture"]:
            img_url = get_text([img_tag])
            if img_url and img_url.startswith("http"):
                images.append({"url": img_url})
        for img_el in node.findall(".//images//image") + node.findall(".//Pictures//Picture"):
            if img_el.text and img_el.text.startswith("http"):
                images.append({"url": img_el.text.strip()})

        variants = (
            node.findall(".//Variant") or 
            node.findall(".//variant") or 
            node.findall(".//Varyant") or 
            node.findall(".//subproduct")
        )

        if variants:
            for var in variants:
                def get_var_text(tags, default=""):
                    for t in tags:
                        el = var.find(t)
                        if el is not None and el.text:
                            return el.text.strip()
                    return default

                numara = get_var_text(["Size", "Numara", "Beden", "Spec1", "value", "name"], "Standart")
                barkod = get_var_text(["Barcode", "Barkod", "barcode", "gtin"], f"{urun_kodu}-{numara}")
                stok_str = get_var_text(["Quantity", "Stok", "Miktar", "stock", "quantity"], "0")
                var_renk = get_var_text(["Color", "Renk", "Spec2"], renk)
                
                try:
                    stok = int(float(stok_str))
                except:
                    stok = 0

                parsed_items.append({
                    "Seç": True,
                    "Model Kodu": urun_kodu,
                    "Barkod": barkod,
                    "Ürün Adı": urun_adi,
                    "Marka": marka,
                    "Kategori": kategori,
                    "Renk": var_renk,
                    "Numara": numara,
                    "Stok": stok,
                    "Alış Fiyatı": alis_fiyati,
                    "Görsel Sayısı": len(images),
                    "Görseller": images,
                    "Açıklama": aciklama
                })
        else:
            numara = get_text(["Size", "Numara", "Beden"], "Standart")
            barkod = get_text(["Barcode", "Barkod", "barcode"], urun_kodu)
            stok_str = get_text(["Quantity", "Stock", "Stok", "Miktar"], "0")
            try:
                stok = int(float(stok_str))
            except:
                stok = 0

            parsed_items.append({
                "Seç": True,
                "Model Kodu": urun_kodu,
                "Barkod": barkod,
                "Ürün Adı": urun_adi,
                "Marka": marka,
                "Kategori": kategori,
                "Renk": renk,
                "Numara": numara,
                "Stok": stok,
                "Alış Fiyatı": alis_fiyati,
                "Görsel Sayısı": len(images),
                "Görseller": images,
                "Açıklama": aciklama
            })

    return pd.DataFrame(parsed_items), raw_sample

def sync_price_and_inventory(df_to_sync, sup_id, key, secret):
    headers = get_trendyol_headers(sup_id, key, secret)
    api_url = f"https://api.trendyol.com/sapigw/suppliers/{sup_id}/products/price-and-inventory"
    
    items_payload = []
    for _, row in df_to_sync.iterrows():
        gonderilecek_stok = int(row["Güncel Stok"])
        satis_fiyati = float(row["Trendyol Satış Fiyatı"])
        
        items_payload.append({
            "barcode": str(row["Barkod"]),
            "quantity": gonderilecek_stok,
            "salePrice": satis_fiyati,
            "listPrice": round(satis_fiyati * 1.15, 2)
        })
    
    chunk_size = 1000
    batch_ids = []
    errors = []
    
    for i in range(0, len(items_payload), chunk_size):
        chunk = items_payload[i:i + chunk_size]
        try:
            res = requests.post(api_url, headers=headers, data=json.dumps({"items": chunk}), timeout=30)
            if res.status_code in [200, 201, 202]:
                b_id = res.json().get("batchRequestId", "Bilinmiyor")
                batch_ids.append(b_id)
            else:
                errors.append(f"HTTP {res.status_code}: {res.text}")
        except Exception as e:
            errors.append(str(e))
            
    return batch_ids, errors

# --- ÜST BUTON: XML ÇEKME ---
fetch_btn = st.button("📥 XML Verilerini Şimdi Çek", use_container_width=True, type="primary")

if fetch_btn:
    with st.spinner("XML Bankası verileri indiriliyor ve ayrıştırılıyor..."):
        try:
            df, sample_xml = fetch_and_parse_xml(xml_url)
            st.session_state["xml_df"] = df
            st.session_state["sample_xml"] = sample_xml
            st.session_state["last_fetch_time"] = datetime.now().strftime("%H:%M:%S")
            st.success(f"Toplam {len(df)} varyant yüklendi! ({st.session_state['last_fetch_time']})")
        except Exception as e:
            st.error(f"XML çekilirken hata oluştu: {e}")

# --- SEKMELER ---
tab1, tab2, tab3, tab4 = st.tabs([
    "📦 1. Ürün Yükle", 
    "🔄 2. Stok & Fiyat", 
    "🔍 3. Batch Sorgu",
    "🏷️ 4. ID Bulucu"
])

# ==============================================================================
# SEKME 1: YENİ ÜRÜN YÜKLEME
# ==============================================================================
with tab1:
    cat_dict = get_category_attributes_dict(default_Category_id)
    
    selected_req_attributes = []
    if cat_dict:
        size_info = cat_dict.get("size_attr")
        color_info = cat_dict.get("color_attr")
        req_attrs = cat_dict.get("required_attrs", [])
        
        st.success(
            f"🎯 **Kategori ({default_Category_id}) Hazır!** | "
            f"**Numara:** `{size_info['name']}` ({len(size_info['values'])} numara) | "
            f"**Renk:** `{color_info['name']}`" if size_info and color_info else 
            f"🎯 **Kategori ({default_Category_id}) Sözlüğü Yüklendi!**"
        )
        
        if req_attrs:
            with st.expander("⚙️ Zorunlu Özellikler (Cinsiyet vb.)", expanded=False):
                for r_attr in req_attrs:
                    if r_attr["values"]:
                        options = {v["name"]: v["id"] for v in r_attr["values"]}
                        chosen_label = st.selectbox(f"🚨 {r_attr['name']}", list(options.keys()), key=f"req_{r_attr['id']}")
                        selected_req_attributes.append({
                            "attributeId": r_attr["id"],
                            "attributeValueId": options[chosen_label]
                        })
                    elif r_attr["allowCustom"]:
                        custom_val = st.text_input(f"🚨 {r_attr['name']}", value="Standart", key=f"req_cust_{r_attr['id']}")
                        selected_req_attributes.append({
                            "attributeId": r_attr["id"],
                            "customAttributeValue": custom_val
                        })
    else:
        st.warning("⚠️ Geçerli bir Kategori ID seçilmedi. 4. Sekmeden kontrol edin.")

    if "xml_df" not in st.session_state or st.session_state["xml_df"].empty:
        st.info("Ürünleri listelemek için yukarıdaki **'📥 XML Verilerini Şimdi Çek'** butonuna dokunun.")
    else:
        df = st.session_state["xml_df"].copy()
        df["Trendyol Satış Fiyatı"] = ((df["Alış Fiyatı"] * (1 + profit_rate / 100)) + extra_cost).round(2)

        if cat_dict and cat_dict.get("size_attr"):
            def preview_size_id(num_str):
                res = resolve_attribute_payload(cat_dict["size_attr"], num_str)
                if res and "attributeValueId" in res:
                    return f"✅ {num_str} ({res['attributeValueId']})"
                elif res and "customAttributeValue" in res:
                    return f"✍️ {num_str}"
                return f"❌ ({num_str})"
            df["Numara Eşleşmesi"] = df["Numara"].apply(preview_size_id)

        search_term = st.text_input("🔍 Ürün Adı veya Model Kodu Ara", key="search_new")
        only_in_stock = st.checkbox("Sadece Stoğu Olanları Göster", value=True, key="stock_new")

        if search_term:
            df = df[df["Ürün Adı"].str.contains(search_term, case=False, na=False) | 
                    df["Model Kodu"].str.contains(search_term, case=False, na=False)]
        if only_in_stock:
            df = df[df["Stok"] > 0]

        edited_df = st.data_editor(
            df.drop(columns=["Görseller", "Açıklama"]),
            use_container_width=True,
            hide_index=True,
            column_config={
                "Seç": st.column_config.CheckboxColumn("Yükle", default=True),
                "Numara": st.column_config.TextColumn("Numara"),
                "Trendyol Satış Fiyatı": st.column_config.NumberColumn("Satış Fiyatı", format="%.2f ₺")
            }
        )

        selected_rows = edited_df[edited_df["Seç"] == True]
        st.write(f"Seçili Varyant Sayısı: **{len(selected_rows)}**")

        if st.button("🚀 Seçili Ürünleri Trendyol'a Yükle", type="primary"):
            if not supplier_id or not api_key or not api_secret:
                st.warning("Lütfen üstteki 'Mobil Hızlı Ayarlar' veya sol menüden Trendyol API bilgilerinizi girin.")
            elif not cat_dict:
                st.error("Geçerli bir Trendyol Kategori ID seçilmedi.")
            else:
                items_payload = []
                for idx, row in selected_rows.iterrows():
                    orig_row = st.session_state["xml_df"].loc[idx]
                    attributes = list(selected_req_attributes)
                    
                    if cat_dict.get("color_attr"):
                        color_payload = resolve_attribute_payload(cat_dict["color_attr"], row["Renk"])
                        if color_payload:
                            attributes.append(color_payload)
                            
                    if cat_dict.get("size_attr"):
                        size_payload = resolve_attribute_payload(cat_dict["size_attr"], row["Numara"])
                        if size_payload:
                            attributes.append(size_payload)

                    gonderilecek_stok = int(row["Stok"]) if int(row["Stok"]) >= min_stock_limit else 0

                    items_payload.append({
                        "barcode": str(row["Barkod"]),
                        "title": str(row["Ürün Adı"])[:100],
                        "productMainId": str(row["Model Kodu"]),
                        "brandId": int(default_brand_id),
                        "categoryId": int(default_Category_id),
                        "quantity": gonderilecek_stok,
                        "stockCode": str(row["Barkod"]),
                        "dimensionalWeight": 2,
                        "description": str(orig_row["Açıklama"]),
                        "currencyType": "TRY",
                        "listPrice": round(float(row["Trendyol Satış Fiyatı"]) * 1.15, 2),
                        "salePrice": float(row["Trendyol Satış Fiyatı"]),
                        "vatRate": int(vat_rate),
                        "images": orig_row["Görseller"] if orig_row["Görseller"] else [{"url": "https://via.placeholder.com/500"}],
                        "attributes": attributes
                    })

                headers = get_trendyol_headers(supplier_id, api_key, api_secret)
                api_url = f"https://api.trendyol.com/sapigw/suppliers/{supplier_id}/v2/products"

                with st.spinner("Ürünler Trendyol'a iletiliyor..."):
                    try:
                        res = requests.post(api_url, headers=headers, data=json.dumps({"items": items_payload[:1000]}), timeout=30)
                        if res.status_code in [200, 201, 202]:
                            batch_id = res.json().get("batchRequestId", "Bilinmiyor")
                            st.session_state["last_batch_id"] = batch_id
                            st.success(f"✅ Kuyruğa alındı! Batch ID: `{batch_id}`")
                        else:
                            st.error(f"❌ Hata ({res.status_code}): {res.text}")
                    except Exception as ex:
                        st.error(f"Bağlantı hatası: {ex}")

# ==============================================================================
# SEKME 2: OTOMATİK STOK & FİYAT GÜNCELLEME
# ==============================================================================
with tab2:
    st.subheader("🔄 Stok ve Fiyat Güncelle")
    if "xml_df" not in st.session_state or st.session_state["xml_df"].empty:
        st.warning("Önce üstteki butondan XML verilerini çekmelisiniz.")
    else:
        sync_df = st.session_state["xml_df"][["Barkod", "Model Kodu", "Ürün Adı", "Renk", "Numara", "Stok", "Alış Fiyatı"]].copy()
        sync_df["Güncel Stok"] = sync_df["Stok"].apply(lambda x: x if x >= min_stock_limit else 0)
        sync_df["Trendyol Satış Fiyatı"] = ((sync_df["Alış Fiyatı"] * (1 + profit_rate / 100)) + extra_cost).round(2)

        st.dataframe(sync_df, use_container_width=True, hide_index=True)

        if st.button("🔄 Tüm Barkodların Stok ve Fiyatını Şimdi Güncelle", type="primary", use_container_width=True):
            if not supplier_id or not api_key or not api_secret:
                st.error("Lütfen Trendyol API bilgilerinizi girin.")
            else:
                with st.spinner(f"{len(sync_df)} barkod güncelleniyor..."):
                    batch_ids, errors = sync_price_and_inventory(sync_df, supplier_id, api_key, api_secret)
                    if batch_ids:
                        st.session_state["last_batch_id"] = batch_ids[-1]
                        st.success(f"✅ Güncellendi! Batch ID: `{', '.join(batch_ids)}`")
                    if errors:
                        for err in errors:
                            st.error(err)

# ==============================================================================
# SEKME 3: BATCH REQUEST SORGULAMA
# ==============================================================================
with tab3:
    st.subheader("🔍 Batch ID Sonucu Sorgula")
    default_batch = st.session_state.get("last_batch_id", "")
    batch_input = st.text_input("Batch Request ID", value=default_batch)
    
    if st.button("Sorgula", type="primary"):
        if not supplier_id or not api_key or not api_secret or not batch_input:
            st.warning("Lütfen API bilgilerinizi ve Batch Request ID girin.")
        else:
            headers = get_trendyol_headers(supplier_id, api_key, api_secret)
            check_url = f"https://api.trendyol.com/sapigw/suppliers/{supplier_id}/products/batch-requests/{batch_input.strip()}"
            
            with st.spinner("Sorgulanıyor..."):
                try:
                    res = requests.get(check_url, headers=headers, timeout=20)
                    if res.status_code == 200:
                        data = res.json()
                        st.write(f"**Durum:** `{data.get('status')}` | **Toplam:** `{data.get('itemCount')}` | **Hatalı:** `{data.get('failedItemCount')}`")
                        items = data.get("items", [])
                        if items:
                            result_rows = []
                            for it in items:
                                barcode = it.get("requestItem", {}).get("barcode", "")
                                status = it.get("status", "")
                                reasons = ", ".join(it.get("failureReasons", []))
                                result_rows.append({"Barkod": barcode, "Durum": status, "Hata Nedeni": reasons})
                            st.dataframe(pd.DataFrame(result_rows), use_container_width=True, hide_index=True)
                    else:
                        st.error(f"Hata ({res.status_code}): {res.text}")
                except Exception as e:
                    st.error(f"Bağlantı hatası: {e}")

# ==============================================================================
# SEKME 4: KATEGORİ, MARKA & NUMARA SÖZLÜĞÜ BULUCU
# ==============================================================================
with tab4:
    st.subheader("🏷️ Marka, Kategori ve Numara ID Bulucu")
    brand_query = st.text_input("🏢 Marka Adı Yazın", value="Chekich")
    if st.button("Marka Ara"):
        if brand_query:
            b_url = f"https://api.trendyol.com/sapigw/brands/by-name?name={brand_query.strip()}"
            try:
                b_res = requests.get(b_url, headers={"User-Agent": "Mozilla/5.0"}, timeout=15)
                if b_res.status_code == 200 and b_res.json():
                    b_df = pd.DataFrame(b_res.json()).rename(columns={"id": "Marka ID", "name": "Marka Adı"})
                    st.dataframe(b_df, use_container_width=True, hide_index=True)
                else:
                    st.warning("Marka bulunamadı.")
            except Exception as e:
                st.error(f"Hata: {e}")

    st.divider()
    cat_query = st.text_input("📂 Kategori Adı Yazın", value="Spor Ayakkabı")
    if st.button("Kategorilerde Ara"):
        with st.spinner("Kategoriler taranıyor..."):
            try:
                cat_df = fetch_trendyol_categories()
                filtered_cats = cat_df[
                    cat_df["Kategori Adı"].str.contains(cat_query, case=False, na=False) |
                    cat_df["Tam Kategori Yolu"].str.contains(cat_query, case=False, na=False)
                ]
                st.dataframe(filtered_cats, use_container_width=True, hide_index=True)
            except Exception as e:
                st.error(f"Hata: {e}")
