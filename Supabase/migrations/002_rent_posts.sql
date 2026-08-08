-- ============================================
-- 002_rent_posts.sql
-- 租房模块数据库表
-- 
-- 📖 这是什么？
-- 这个文件创建租房相关的数据库表
-- 存储房源的详细信息（价格、位置、卧室数等）
-- 
-- 🔗 和 posts 表的关系：
-- 每个租房帖子在 posts 表有一条基础记录
-- 在 rent_posts 表有一条详细记录
-- 两者通过相同的 id 关联
-- ============================================


-- ============================================
-- 租房详情表 (rent_posts)
-- ============================================
-- 
-- 🎯 这个表的作用：
-- 存储租房帖子特有的信息
-- 比如价格、地址、房型、是否允许宠物等
-- 
-- 📝 设计说明：
-- id 是主键，同时也是外键，关联到 posts 表
-- 这种设计叫做"共享主键"，保证了一对一关系

CREATE TABLE rent_posts (
  -- id 既是主键也是外键
  -- REFERENCES posts(id) 表示这个 id 必须在 posts 表中存在
  -- ON DELETE CASCADE 表示如果 posts 中的记录被删除，这条也自动删除
  id UUID PRIMARY KEY REFERENCES posts(id) ON DELETE CASCADE,
  
  -- ============================================
  -- 价格信息
  -- ============================================
  -- price 月租金
  -- NUMERIC(10,2) 表示最多10位数字，小数点后2位
  -- 比如 1500.00 或 99999999.99
  -- CHECK (price > 0) 确保价格是正数
  price NUMERIC(10,2) NOT NULL CHECK (price > 0),
  
  -- ============================================
  -- 位置信息
  -- ============================================
  -- location 房屋地址，必填
  location TEXT NOT NULL,
  
  -- latitude 和 longitude 是地理坐标
  -- 用于在地图上显示房源位置
  -- NUMERIC(10,8) 可以存储精确到小数点后8位的坐标
  latitude NUMERIC(10,8),
  longitude NUMERIC(11,8),
  
  -- ============================================
  -- 房屋规格
  -- ============================================
  -- bedrooms 卧室数量
  -- CHECK (bedrooms >= 0) 确保不是负数，0 表示 Studio
  bedrooms INTEGER CHECK (bedrooms >= 0),
  
  -- bathrooms 卫生间数量
  -- 用 NUMERIC(3,1) 因为可能是 1.5（半浴室）
  bathrooms NUMERIC(3,1) CHECK (bathrooms >= 0),
  
  -- specs 用户自定义规格描述
  -- 比如 "Loft"、"双层"、"带阁楼" 等
  specs TEXT,
  
  -- property_type 房屋类型
  -- studio: 开间（无独立卧室）
  -- apartment: 公寓
  -- house: 独栋房屋
  -- condo: 产权公寓
  -- room: 单间出租
  property_type TEXT NOT NULL CHECK (property_type IN ('studio', 'apartment', 'house', 'condo', 'room')),
  
  -- ============================================
  -- 可用性信息
  -- ============================================
  -- is_available 是否还在出租
  -- 出租后设为 FALSE
  is_available BOOLEAN DEFAULT TRUE,
  
  -- available_from 可入住日期
  -- DATE 类型只存储日期，不存储时间
  available_from DATE,
  
  -- lease_duration 租期要求
  -- 比如 "6 months"、"1 year"、"flexible"
  lease_duration TEXT,
  
  -- ============================================
  -- 设施信息
  -- ============================================
  -- utilities_included 是否包水电费
  utilities_included BOOLEAN DEFAULT FALSE,
  
  -- pets_allowed 是否允许养宠物
  pets_allowed BOOLEAN DEFAULT FALSE,
  
  -- parking_available 是否有停车位
  parking_available BOOLEAN DEFAULT FALSE,
  
  -- laundry_type 洗衣设施类型
  -- in_unit: 房间内有洗衣机
  -- in_building: 楼内有公共洗衣房
  -- none: 没有洗衣设施
  laundry_type TEXT CHECK (laundry_type IN ('in_unit', 'in_building', 'none')),
  
  -- amenities 其他设施
  -- JSONB 是 PostgreSQL 的 JSON 二进制格式，可以存储数组
  -- 比如 ["gym", "pool", "doorman"]
  amenities JSONB DEFAULT '[]'::JSONB
);


-- ============================================
-- 创建索引优化查询速度
-- ============================================

-- 位置全文搜索索引
-- 方便用户搜索 "UCLA" 或 "Westwood" 等关键词
CREATE INDEX rent_posts_location_idx ON rent_posts USING GIN (to_tsvector('english', location));

-- 价格索引，用于价格排序和范围筛选
CREATE INDEX rent_posts_price_idx ON rent_posts (price);

-- 只索引可用的房源，提高列表查询速度
-- WHERE is_available = TRUE 叫做"部分索引"
CREATE INDEX rent_posts_available_idx ON rent_posts (is_available) WHERE is_available = TRUE;

-- 卧室数量索引，用于按卧室筛选
CREATE INDEX rent_posts_bedrooms_idx ON rent_posts (bedrooms);

-- 房型索引
CREATE INDEX rent_posts_property_type_idx ON rent_posts (property_type);

-- 可用房源的价格范围索引
-- 这是为了优化"筛选价格范围内的可用房源"这种常见查询
CREATE INDEX rent_posts_price_range_idx ON rent_posts (price) WHERE is_available = TRUE;


-- ============================================
-- 创建租房帖子的便捷函数
-- ============================================
-- 
-- 🎯 这个函数的作用：
-- 一次性创建帖子和租房详情
-- 而不需要分两步操作
-- 
-- 📝 使用方法：
-- SELECT create_rent_post(
--   p_user_id := '用户ID',
--   p_title := '标题',
--   p_price := 1500,
--   p_location := '地址',
--   ...
-- );
-- 
-- 返回值是新创建的帖子 ID

CREATE OR REPLACE FUNCTION create_rent_post(
  -- 函数参数列表
  -- 参数名以 p_ 开头，避免和列名混淆
  p_user_id UUID,               -- 发布者 ID
  p_title TEXT,                 -- 帖子标题
  p_description TEXT,           -- 帖子描述
  p_price NUMERIC,              -- 月租金
  p_location TEXT,              -- 地址
  p_bedrooms INTEGER DEFAULT NULL,        -- 卧室数（可选）
  p_bathrooms NUMERIC DEFAULT NULL,       -- 卫生间数（可选）
  p_specs TEXT DEFAULT NULL,              -- 自定义规格（可选）
  p_property_type TEXT DEFAULT 'apartment', -- 房型（默认公寓）
  p_available_from DATE DEFAULT NULL,     -- 入住日期（可选）
  p_lease_duration TEXT DEFAULT NULL,     -- 租期（可选）
  p_utilities_included BOOLEAN DEFAULT FALSE, -- 是否包水电
  p_pets_allowed BOOLEAN DEFAULT FALSE,   -- 是否允许宠物
  p_is_anonymous BOOLEAN DEFAULT FALSE    -- 是否匿名
)
RETURNS UUID AS $$  -- 返回类型是 UUID（帖子 ID）
DECLARE
  -- 声明一个变量来存储新帖子的 ID
  v_post_id UUID;
BEGIN
  -- 第一步：在 posts 表创建基础记录
  INSERT INTO posts (user_id, type, title, description, is_anonymous)
  VALUES (p_user_id, 'rent', p_title, p_description, p_is_anonymous)
  -- RETURNING id INTO v_post_id 把新创建的 ID 存到变量中
  RETURNING id INTO v_post_id;
  
  -- 第二步：在 rent_posts 表创建详情记录
  -- 注意 id 使用的是刚才创建的 v_post_id
  INSERT INTO rent_posts (
    id, price, location, bedrooms, bathrooms, specs,
    property_type, available_from, lease_duration,
    utilities_included, pets_allowed
  )
  VALUES (
    v_post_id, p_price, p_location, p_bedrooms, p_bathrooms, p_specs,
    p_property_type, p_available_from, p_lease_duration,
    p_utilities_included, p_pets_allowed
  );
  
  -- 返回新帖子的 ID
  RETURN v_post_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 创建租房列表视图
-- ============================================
-- 
-- 🎯 什么是视图（VIEW）？
-- 视图就像一个"虚拟表"
-- 它不实际存储数据，而是保存一个查询
-- 每次查询视图时，都会执行这个查询
-- 
-- 🎯 这个视图的作用：
-- 把 rent_posts、posts、profiles 三个表的数据合并
-- 方便 App 一次性获取租房帖子的所有信息
-- 
-- 📝 好处：
-- 1. 简化前端代码，一次查询获取所有需要的数据
-- 2. 可以在视图中添加计算字段（如图片列表）
-- 3. 隐藏复杂的 JOIN 逻辑

CREATE OR REPLACE VIEW rent_posts_view AS
SELECT 
  -- 租房详情表的所有字段
  r.*,
  
  -- 从 posts 表获取的字段
  p.user_id,          -- 发布者 ID
  p.title,            -- 标题
  p.description,      -- 描述
  p.status,           -- 状态
  p.is_anonymous,     -- 是否匿名
  p.view_count,       -- 浏览次数
  p.created_at,       -- 创建时间
  p.updated_at,       -- 更新时间
  
  -- 从 profiles 表获取的用户信息
  pr.full_name AS user_name,         -- 发布者昵称
  pr.avatar_url AS user_avatar,      -- 发布者头像
  pr.university AS user_university,  -- 发布者学校
  pr.verified AS user_verified,      -- 发布者是否认证
  
  -- ============================================
  -- 图片列表（子查询）
  -- ============================================
  -- 这是一个"相关子查询"，为每个帖子获取其所有图片
  -- json_agg 把多行数据聚合成一个 JSON 数组
  -- json_build_object 创建 JSON 对象
  -- ORDER BY pi.order_index 按顺序排列
  -- COALESCE(..., '[]'::json) 如果没有图片，返回空数组
  COALESCE(
    (SELECT json_agg(
      json_build_object(
        'id', pi.id, 
        'url', pi.url, 
        'order_index', pi.order_index
      ) ORDER BY pi.order_index
    )
     FROM post_images pi WHERE pi.post_id = r.id),
    '[]'::json
  ) AS images

-- 表连接（JOIN）
FROM rent_posts r
-- INNER JOIN 只返回两个表都有的数据
JOIN posts p ON r.id = p.id
JOIN profiles pr ON p.user_id = pr.id

-- 只显示活跃状态的帖子
WHERE p.status = 'active';


-- ============================================
-- 🎉 完成！
-- ============================================
-- 
-- 执行完这个文件后，你就有了：
-- 1. rent_posts 表 - 存储租房详细信息
-- 2. 多个索引 - 优化查询速度
-- 3. create_rent_post 函数 - 便捷创建租房帖子
-- 4. rent_posts_view 视图 - 一次性获取完整租房信息
-- 
-- 下一步：执行 003_secondhand_posts.sql 创建二手交易表
