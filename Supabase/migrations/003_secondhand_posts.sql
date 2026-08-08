-- ============================================
-- 003_secondhand_posts.sql
-- 二手交易模块数据库表
-- 
-- 📖 这是什么？
-- 这个文件创建二手交易相关的数据库表
-- 用于存储二手物品的详细信息
-- 
-- 🔗 和 posts 表的关系：
-- 和 rent_posts 类似，每个二手帖子：
-- 1. 在 posts 表有一条基础记录
-- 2. 在 secondhand_posts 表有一条详情记录
-- ============================================


-- ============================================
-- 二手交易详情表 (secondhand_posts)
-- ============================================
-- 
-- 🎯 这个表存储二手物品的特有信息
-- 包括：价格、分类、成色、是否可议价等

CREATE TABLE secondhand_posts (
  -- 主键，同时也是外键
  -- 和 posts 表的 id 对应
  id UUID PRIMARY KEY REFERENCES posts(id) ON DELETE CASCADE,
  
  -- ============================================
  -- 价格信息
  -- ============================================
  
  -- price 商品价格
  -- NUMERIC(10,2) 最多10位数字，2位小数
  price NUMERIC(10,2) NOT NULL CHECK (price >= 0),
  
  -- original_price 原价（可选）
  -- 用于显示折扣：原价 $100，现价 $50
  original_price NUMERIC(10,2) CHECK (original_price >= 0),
  
  -- is_negotiable 是否可议价
  is_negotiable BOOLEAN DEFAULT TRUE,
  
  -- is_free 是否免费赠送
  is_free BOOLEAN DEFAULT FALSE,
  
  -- ============================================
  -- 分类信息
  -- ============================================
  -- 
  -- 📝 分类列表：
  -- electronics: 电子产品（手机、电脑、相机等）
  -- furniture: 家具（桌椅、床、沙发等）
  -- clothing: 服饰（衣服、鞋子、包等）
  -- books: 书籍教材
  -- appliances: 家电（微波炉、电饭煲等）
  -- sports: 运动户外
  -- beauty: 美妆个护
  -- other: 其他
  
  category TEXT NOT NULL CHECK (category IN (
    'electronics', 'furniture', 'clothing', 'books',
    'appliances', 'sports', 'beauty', 'other'
  )),
  
  -- ============================================
  -- 商品状态
  -- ============================================
  -- 
  -- 📝 成色说明：
  -- new: 全新（未使用）
  -- like_new: 几乎全新（使用很少，无明显痕迹）
  -- good: 良好（正常使用痕迹）
  -- fair: 一般（有些磨损但功能正常）
  -- poor: 较差（有明显问题或瑕疵）
  
  condition TEXT NOT NULL CHECK (condition IN (
    'new', 'like_new', 'good', 'fair', 'poor'
  )),
  
  -- ============================================
  -- 交易方式
  -- ============================================
  
  -- pickup_location 自取地点
  -- 买家来这里拿货
  pickup_location TEXT,
  
  -- can_ship 是否支持邮寄
  can_ship BOOLEAN DEFAULT FALSE,
  
  -- shipping_fee 邮费（如果支持邮寄）
  -- NULL 表示包邮或者不支持邮寄
  shipping_fee NUMERIC(10,2) CHECK (shipping_fee >= 0),
  
  -- ============================================
  -- 库存信息
  -- ============================================
  
  -- quantity 库存数量
  -- 默认为 1，允许卖多个相同商品
  quantity INTEGER DEFAULT 1 CHECK (quantity >= 0),
  
  -- sold_count 已卖出数量
  sold_count INTEGER DEFAULT 0 CHECK (sold_count >= 0)
);


-- ============================================
-- 创建索引
-- ============================================

-- 分类索引，用于按类别筛选
CREATE INDEX secondhand_posts_category_idx ON secondhand_posts (category);

-- 价格索引，用于价格排序和范围筛选
CREATE INDEX secondhand_posts_price_idx ON secondhand_posts (price);

-- 成色索引，用于按成色筛选
CREATE INDEX secondhand_posts_condition_idx ON secondhand_posts (condition);

-- 免费物品索引
CREATE INDEX secondhand_posts_free_idx ON secondhand_posts (is_free) WHERE is_free = TRUE;


-- ============================================
-- 创建二手帖子的便捷函数
-- ============================================

CREATE OR REPLACE FUNCTION create_secondhand_post(
  p_user_id UUID,               -- 发布者 ID
  p_title TEXT,                 -- 标题
  p_description TEXT,           -- 描述
  p_price NUMERIC,              -- 价格
  p_category TEXT,              -- 分类
  p_condition TEXT,             -- 成色
  p_original_price NUMERIC DEFAULT NULL,    -- 原价
  p_is_negotiable BOOLEAN DEFAULT TRUE,     -- 可议价
  p_is_free BOOLEAN DEFAULT FALSE,          -- 免费
  p_pickup_location TEXT DEFAULT NULL,      -- 自取地点
  p_can_ship BOOLEAN DEFAULT FALSE,         -- 可邮寄
  p_quantity INTEGER DEFAULT 1,             -- 数量
  p_is_anonymous BOOLEAN DEFAULT FALSE      -- 匿名
)
RETURNS UUID AS $$
DECLARE
  v_post_id UUID;
BEGIN
  -- 创建基础帖子记录
  INSERT INTO posts (user_id, type, title, description, is_anonymous)
  VALUES (p_user_id, 'secondhand', p_title, p_description, p_is_anonymous)
  RETURNING id INTO v_post_id;
  
  -- 创建二手详情记录
  INSERT INTO secondhand_posts (
    id, price, original_price, is_negotiable, is_free,
    category, condition, pickup_location, can_ship, quantity
  )
  VALUES (
    v_post_id, p_price, p_original_price, p_is_negotiable, p_is_free,
    p_category, p_condition, p_pickup_location, p_can_ship, p_quantity
  );
  
  RETURN v_post_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 创建二手帖子视图
-- ============================================
-- 
-- 🎯 视图的作用：
-- 把 secondhand_posts、posts、profiles 三个表合并
-- 前端查询时只需要查这个视图

CREATE OR REPLACE VIEW secondhand_posts_view AS
SELECT 
  -- 二手详情字段
  s.*,
  -- 基础帖子字段
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.view_count,
  p.created_at,
  p.updated_at,
  -- 用户信息
  pr.full_name AS user_name,
  pr.avatar_url AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  -- 图片列表
  COALESCE(
    (SELECT json_agg(
      json_build_object('id', pi.id, 'url', pi.url, 'order_index', pi.order_index)
      ORDER BY pi.order_index
    ) FROM post_images pi WHERE pi.post_id = s.id),
    '[]'::json
  ) AS images,
  -- 计算折扣百分比
  -- 如果有原价，计算 (原价-现价)/原价 * 100
  CASE 
    WHEN s.original_price IS NOT NULL AND s.original_price > 0 
    THEN ROUND((1 - s.price / s.original_price) * 100)
    ELSE NULL 
  END AS discount_percent
FROM secondhand_posts s
JOIN posts p ON s.id = p.id
JOIN profiles pr ON p.user_id = pr.id
WHERE p.status = 'active';


-- ============================================
-- 🎉 完成！
-- ============================================
-- 
-- 这个文件创建了：
-- 1. secondhand_posts 表 - 存储二手物品详情
-- 2. 索引 - 优化查询速度
-- 3. create_secondhand_post 函数 - 便捷创建帖子
-- 4. secondhand_posts_view 视图 - 聚合查询数据
